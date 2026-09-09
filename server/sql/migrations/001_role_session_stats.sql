-- One-time migration for databases created before accounts.sql was canonical.
-- Run each statement only when the table/column/index is absent.  MySQL
-- versions differ on IF NOT EXISTS for ALTER TABLE, so this file is explicit.
CREATE TABLE sessions (
  token CHAR(64) NOT NULL,
  account_id CHAR(32) NOT NULL,
  expires_at BIGINT NOT NULL,
  revoked BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (token),
  KEY ix_sessions_account (account_id),
  KEY ix_sessions_expiry (expires_at),
  CONSTRAINT fk_sessions_account FOREIGN KEY (account_id) REFERENCES accounts(account_id)
) ENGINE=InnoDB;

CREATE TABLE roles (
  role_id CHAR(32) NOT NULL,
  account_id CHAR(32) NOT NULL,
  role_name VARCHAR(64) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (role_id),
  UNIQUE KEY uq_roles_account (account_id),
  CONSTRAINT fk_roles_account FOREIGN KEY (account_id) REFERENCES accounts(account_id),
  CONSTRAINT fk_roles_account_role FOREIGN KEY (role_id) REFERENCES accounts(role_id)
) ENGINE=InnoDB;

-- accounts.sql already defines these sessions columns and indexes.

CREATE TABLE role_stats (
  role_id CHAR(32) NOT NULL,
  games INT NOT NULL DEFAULT 0,
  wins INT NOT NULL DEFAULT 0,
  top2 INT NOT NULL DEFAULT 0,
  ladder INT NOT NULL DEFAULT 1000,
  ladder_max INT NOT NULL DEFAULT 1000,
  PRIMARY KEY (role_id),
  CONSTRAINT fk_role_stats_role FOREIGN KEY (role_id) REFERENCES roles(role_id)
) ENGINE=InnoDB;

CREATE TABLE stat_settlements (
  settlement_id VARCHAR(128) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (settlement_id)
) ENGINE=InnoDB;
