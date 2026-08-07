--
-- PostgreSQL database dump
--

\restrict gircAqVRz05dGyDbCHktUnyzE1e6ZG6ZmDp6bL1GVP8DyEkEm9kmVKzcTw1Qugk

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
-- Name: runners_workspace_root_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX runners_workspace_root_index ON public.runners USING btree (workspace_root);


--
-- PostgreSQL database dump complete
--

\unrestrict gircAqVRz05dGyDbCHktUnyzE1e6ZG6ZmDp6bL1GVP8DyEkEm9kmVKzcTw1Qugk

INSERT INTO public."schema_migrations" (version) VALUES (20260807073017);
