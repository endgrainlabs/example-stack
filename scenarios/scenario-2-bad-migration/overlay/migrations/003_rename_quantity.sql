-- +goose Up
-- Scenario 2: Rename quantity to qty.
-- This migration succeeds, but rust-inventory queries reference "quantity"
-- and will fail with "column quantity does not exist".
ALTER TABLE inventory RENAME COLUMN quantity TO qty;

-- +goose Down
ALTER TABLE inventory RENAME COLUMN qty TO quantity;
