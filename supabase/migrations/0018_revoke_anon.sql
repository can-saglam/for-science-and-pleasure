-- Defence in depth: the anon role gets no table access at all.
--
-- Supabase grants anon/authenticated every privilege on new public tables
-- by default and relies on RLS to say no. RLS does say no today (verified:
-- anon reads zero rows from every table, and even app_config is read with
-- a signed-in token). But a future policy written `to public` or
-- `to anon, authenticated` by mistake would silently open a table to the
-- world. With the grants gone, such a policy would still return nothing.
--
-- Auth (GoTrue) and the edge functions are unaffected: sign-in talks to the
-- auth schema, functions use either the caller's JWT (authenticated) or the
-- service role.

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon;

-- Tables created by future migrations get the same treatment.
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public revoke all on functions from anon;
