-- One-off, run ONLY on the VPS's restored copy — never against Supabase.
-- Keeps :owner plus the agent users that appear in their chats; drops the rest.
\set ON_ERROR_STOP on
\set owner 'mohammad'

BEGIN;

CREATE TEMP TABLE keep_users ON COMMIT DROP AS
WITH me AS (SELECT id FROM users WHERE username = :'owner'),
     mychats AS (SELECT chat_id FROM chat_participants WHERE user_id = (SELECT id FROM me))
SELECT id FROM me
UNION
SELECT agent_user_id FROM agents WHERE owner_user_id = (SELECT id FROM me)
UNION
SELECT m.from_id
  FROM messages m
  JOIN users u ON u.id = m.from_id AND u.is_agent
 WHERE m.chat_id IN (SELECT chat_id FROM mychats);

-- Abort rather than delete everything if the owner name ever stops matching.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM keep_users) THEN
    RAISE EXCEPTION 'keep set is empty — owner username did not match';
  END IF;
END $$;

\echo 'users kept / dropped:'
SELECT (SELECT count(*) FROM keep_users) AS keep,
       (SELECT count(*) FROM users WHERE id NOT IN (SELECT id FROM keep_users)) AS drop;

-- These two FKs are NO ACTION, so their rows block the user delete.
DELETE FROM channel_invite_links WHERE created_by NOT IN (SELECT id FROM keep_users);
DELETE FROM channel_agent_assignments WHERE created_by NOT IN (SELECT id FROM keep_users);

DELETE FROM users WHERE id NOT IN (SELECT id FROM keep_users);

-- Chats left with nobody (or one side) after the cascade are dead test DMs.
DELETE FROM chats c
 WHERE (SELECT count(*) FROM chat_participants cp WHERE cp.chat_id = c.id) < 2;

\echo 'after prune:'
SELECT (SELECT count(*) FROM users) AS users,
       (SELECT count(*) FROM chats) AS chats,
       (SELECT count(*) FROM messages) AS messages;

COMMIT;
