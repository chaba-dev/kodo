--
-- PostgreSQL database dump
--

\restrict AemFvrw0hdWx316hOzgPxdZlfQMOsMB7QItpP53CDeRPjDgcKclZCO00ecJgfbO

-- Dumped from database version 17.10
-- Dumped by pg_dump version 18.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: runners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.runners (
    id uuid NOT NULL,
    workspace_root character varying(1024) NOT NULL,
    name character varying(255),
    platform character varying(64) NOT NULL,
    architecture character varying(64) NOT NULL,
    runner_version character varying(64) NOT NULL,
    protocol_version integer NOT NULL,
    capabilities character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    last_connected_at timestamp without time zone,
    last_seen_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: session_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.session_events (
    id uuid NOT NULL,
    session_id uuid NOT NULL,
    sequence bigint NOT NULL,
    type character varying(64) NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    source character varying(32) NOT NULL,
    parent_id uuid,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id uuid NOT NULL,
    runner_id uuid NOT NULL,
    title character varying(255) NOT NULL,
    status character varying(32) NOT NULL,
    model character varying(255) NOT NULL,
    next_event_sequence bigint DEFAULT 1 NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT sessions_next_event_sequence_positive CHECK ((next_event_sequence > 0))
);


--
-- Name: runners runners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runners
    ADD CONSTRAINT runners_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: session_events session_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.session_events
    ADD CONSTRAINT session_events_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: runners_workspace_root_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX runners_workspace_root_index ON public.runners USING btree (workspace_root);


--
-- Name: session_events_session_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX session_events_session_id_inserted_at_index ON public.session_events USING btree (session_id, inserted_at);


--
-- Name: session_events_session_id_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX session_events_session_id_sequence_index ON public.session_events USING btree (session_id, sequence);


--
-- Name: sessions_runner_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sessions_runner_id_index ON public.sessions USING btree (runner_id);


--
-- Name: session_events session_events_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.session_events
    ADD CONSTRAINT session_events_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sessions(id) ON DELETE CASCADE;


--
-- Name: sessions sessions_runner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_runner_id_fkey FOREIGN KEY (runner_id) REFERENCES public.runners(id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--

\unrestrict AemFvrw0hdWx316hOzgPxdZlfQMOsMB7QItpP53CDeRPjDgcKclZCO00ecJgfbO

INSERT INTO public."schema_migrations" (version) VALUES (20260807073017);
INSERT INTO public."schema_migrations" (version) VALUES (20260808062115);
