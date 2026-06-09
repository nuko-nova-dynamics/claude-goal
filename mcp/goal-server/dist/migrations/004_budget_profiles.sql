ALTER TABLE goals
  ADD COLUMN budget_profile TEXT CHECK(budget_profile IN ('quick','standard','deep','overnight') OR budget_profile IS NULL);

ALTER TABLE goals
  ADD COLUMN budget_source TEXT NOT NULL DEFAULT 'none' CHECK(budget_source IN ('none','tokens','profile','auto'));

UPDATE goals
SET budget_source = CASE
  WHEN token_budget IS NOT NULL THEN 'tokens'
  ELSE 'none'
END;

UPDATE schema_version SET version = 4;
