-- init_db.sql — schema + least-privilege users (app, backup, repl).
-- Replace every STRONG_*_PASS placeholder before running in any real environment.
-- Apply: mysql -u root -p < scripts/init_db.sql

SET @OLD_SQL_MODE = @@SQL_MODE;
SET SESSION sql_mode = 'STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION';

-- ---------------------------------------------------------------------------
-- Database
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS appdb
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE appdb;

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS items (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  name       VARCHAR(255) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_items_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Least-privilege users
-- ---------------------------------------------------------------------------

-- App user: CRUD only, restricted to the app subnet.
CREATE USER IF NOT EXISTS 'appuser'@'10.0.1.%' IDENTIFIED BY 'STRONG_APP_PASS';
GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'appuser'@'10.0.1.%';

-- Backup user: read + lock + binlog access, local socket only.
CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY 'STRONG_BACKUP_PASS';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER, RELOAD, REPLICATION CLIENT
  ON *.* TO 'backup'@'localhost';

-- Replication user: replica in the private subnet only.
CREATE USER IF NOT EXISTS 'repl'@'10.0.2.%' IDENTIFIED BY 'STRONG_REPL_PASS';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl'@'10.0.2.%';

FLUSH PRIVILEGES;

SET SESSION sql_mode = @OLD_SQL_MODE;
