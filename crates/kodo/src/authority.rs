//! Runner-enforced leases for control-plane session ownership.

use std::collections::HashMap;
use std::future::pending;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use thiserror::Error;
use tokio::sync::Notify;
use tokio::time::Instant;
use uuid::Uuid;

use crate::protocol::{AuthorityLease, MAX_AUTHORITY_LEASE_MS};

#[derive(Clone, Default)]
pub(crate) struct AuthorityRegistry {
    inner: Arc<AuthorityRegistryInner>,
}

#[derive(Default)]
struct AuthorityRegistryInner {
    sessions: Mutex<HashMap<Uuid, LeaseState>>,
    changed: Notify,
}

#[derive(Clone, Copy)]
struct LeaseState {
    ownership_epoch: u64,
    generation: u64,
    expires_at: Instant,
}

#[derive(Clone)]
pub(crate) struct AuthorityGuard {
    registry: Option<AuthorityRegistry>,
    session_id: Uuid,
    ownership_epoch: u64,
    generation: u64,
}

#[derive(Debug, Error)]
pub(crate) enum AuthorityError {
    #[error("authority lease ownership epoch must be positive")]
    InvalidEpoch,
    #[error("authority lease TTL must be between 1 and {MAX_AUTHORITY_LEASE_MS} milliseconds")]
    InvalidTtl,
    #[error("authority lease was superseded by ownership epoch {current_epoch}")]
    Stale { current_epoch: u64 },
    #[error("authority lease expired or was superseded")]
    Lost,
}

impl AuthorityRegistry {
    pub(crate) fn grant(&self, lease: AuthorityLease) -> Result<AuthorityGuard, AuthorityError> {
        if lease.ownership_epoch == 0 {
            return Err(AuthorityError::InvalidEpoch);
        }
        if lease.ttl_ms == 0 || lease.ttl_ms > MAX_AUTHORITY_LEASE_MS {
            return Err(AuthorityError::InvalidTtl);
        }

        let now = Instant::now();
        let mut sessions = self
            .inner
            .sessions
            .lock()
            .expect("authority registry lock poisoned");
        let previous = sessions.get(&lease.session_id).copied();
        if let Some(state) = previous
            && lease.ownership_epoch < state.ownership_epoch
        {
            return Err(AuthorityError::Stale {
                current_epoch: state.ownership_epoch,
            });
        }

        let generation = match previous {
            Some(state)
                if state.ownership_epoch == lease.ownership_epoch && state.expires_at > now =>
            {
                state.generation
            }
            Some(state) => state.generation.wrapping_add(1),
            None => 0,
        };
        sessions.insert(
            lease.session_id,
            LeaseState {
                ownership_epoch: lease.ownership_epoch,
                generation,
                expires_at: now + Duration::from_millis(lease.ttl_ms),
            },
        );
        drop(sessions);
        self.inner.changed.notify_waiters();

        Ok(AuthorityGuard {
            registry: Some(self.clone()),
            session_id: lease.session_id,
            ownership_epoch: lease.ownership_epoch,
            generation,
        })
    }
}

impl AuthorityGuard {
    pub(crate) fn unmanaged() -> Self {
        Self {
            registry: None,
            session_id: Uuid::nil(),
            ownership_epoch: 0,
            generation: 0,
        }
    }

    pub(crate) fn ensure_valid(&self) -> Result<(), AuthorityError> {
        let Some(registry) = &self.registry else {
            return Ok(());
        };
        let sessions = registry
            .inner
            .sessions
            .lock()
            .expect("authority registry lock poisoned");
        let valid = sessions.get(&self.session_id).is_some_and(|state| {
            state.ownership_epoch == self.ownership_epoch
                && state.generation == self.generation
                && state.expires_at > Instant::now()
        });
        if valid {
            Ok(())
        } else {
            Err(AuthorityError::Lost)
        }
    }

    pub(crate) async fn wait_until_invalid(&self) {
        let Some(registry) = &self.registry else {
            pending::<()>().await;
            return;
        };

        loop {
            let changed = registry.inner.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            let expires_at = {
                let sessions = registry
                    .inner
                    .sessions
                    .lock()
                    .expect("authority registry lock poisoned");
                match sessions.get(&self.session_id) {
                    Some(state)
                        if state.ownership_epoch == self.ownership_epoch
                            && state.generation == self.generation
                            && state.expires_at > Instant::now() =>
                    {
                        state.expires_at
                    }
                    _ => return,
                }
            };

            tokio::select! {
                () = tokio::time::sleep_until(expires_at) => {}
                () = &mut changed => {}
            }
        }
    }
}
