CREATE TABLE accounts (
  account_id CHAR(32) NOT NULL,
  role_id CHAR(32) NOT NULL,
  account_name VARCHAR(64) CHARACTER SET ascii NOT NULL,
  password_salt VARBINARY(16) NOT NULL,
  password_hash VARBINARY(32) NOT NULL,
  tutorial_completed BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (account_id),
  UNIQUE KEY uq_accounts_name (account_name)
  ,UNIQUE KEY uq_accounts_role_id (role_id)
) ENGINE=InnoDB;

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
