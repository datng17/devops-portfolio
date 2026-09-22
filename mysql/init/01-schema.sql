-- Schema, seed table, and least-privilege users.
-- Replace the STRONG_*_PASS placeholders before running in any real environment.

CREATE DATABASE IF NOT EXISTS appdb
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE appdb;

CREATE TABLE IF NOT EXISTS items (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Application user: CRUD only, restricted to the public app subnet
CREATE USER IF NOT EXISTS 'appuser'@'10.0.1.%' IDENTIFIED BY 'STRONG_APP_PASS';
GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'appuser'@'10.0.1.%';

-- Backup user: read + lock, local only
CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY 'STRONG_BACKUP_PASS';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER, RELOAD ON *.* TO 'backup'@'localhost';

-- Replication user (optional replica in the private subnet)
CREATE USER IF NOT EXISTS 'repl'@'10.0.2.%' IDENTIFIED BY 'STRONG_REPL_PASS';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'10.0.2.%';

FLUSH PRIVILEGES;
