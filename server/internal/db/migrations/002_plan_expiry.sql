-- Optional end date for a user's plan. After it passes the user is treated as
-- being on the default plan (see DB.EffectivePlan); NULL means no end date.
ALTER TABLE users ADD COLUMN plan_expires_at timestamptz;
