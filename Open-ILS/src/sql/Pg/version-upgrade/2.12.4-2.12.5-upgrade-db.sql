--Upgrade Script for 2.12.4 to 2.12.5
\set eg_version '''2.12.5'''
BEGIN;
INSERT INTO config.upgrade_log (version, applied_to) VALUES ('2.12.5', :eg_version);
COMMIT;
