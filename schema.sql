-- ============================================================
-- Project 2: Job Reporting Tool
-- SQLite database schema
-- ============================================================
--
-- Design decisions:
--
-- 1. jobs represents one logical job.
--
-- 2. job_attempts represents every processing attempt.
--
-- 3. A job may therefore have multiple attempt rows.
--
-- 4. A job's final status is the status associated with its
--    highest-numbered attempt.
--
-- 5. Project 2 uses a batch-reload ingestion model for v1.
--    The database represents one imported CSV dataset at a time.
--
-- 6. The CSV produced by Project 1 is the integration contract.
--    Project 1 remains independent of the database.
--
-- 7. created_at means the timestamp of the job's first recorded
--    processing attempt. Project 1 does not currently expose a
--    separate job-submission timestamp in its CSV output.
--
-- 8. Invalid jobs are not represented in this database because
--    Project 1 does not write invalid jobs to its structured CSV.
--    Invalid-job handling remains the responsibility of Project 1.
--
-- ============================================================


PRAGMA foreign_keys = ON;


-- ============================================================
-- Logical jobs
-- ============================================================

CREATE TABLE IF NOT EXISTS jobs (
    job_id TEXT PRIMARY KEY,

    priority TEXT NOT NULL
        CHECK (priority IN (
            'critical',
            'high',
            'medium',
            'low'
        )),

    type TEXT NOT NULL,

    status TEXT NOT NULL
        CHECK (status IN (
            'SUCCESS',
            'FAILURE'
        )),

    total_attempts INTEGER NOT NULL
        CHECK (total_attempts > 0),

    created_at TEXT NOT NULL,

    completed_at TEXT NOT NULL
);


-- ============================================================
-- Individual processing attempts
-- ============================================================

CREATE TABLE IF NOT EXISTS job_attempts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,

    job_id TEXT NOT NULL,

    attempt INTEGER NOT NULL
        CHECK (attempt > 0),

    status TEXT NOT NULL
        CHECK (status IN (
            'SUCCESS',
            'FAILURE'
        )),

    priority TEXT NOT NULL
        CHECK (priority IN (
            'critical',
            'high',
            'medium',
            'low'
        )),

    type TEXT NOT NULL,

    recorded_at TEXT NOT NULL,

    FOREIGN KEY (job_id)
        REFERENCES jobs(job_id)
        ON DELETE CASCADE,

    UNIQUE (job_id, attempt)
);


-- ============================================================
-- Indexes supporting reporting queries
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_job_attempts_job_id
    ON job_attempts(job_id);

CREATE INDEX IF NOT EXISTS idx_job_attempts_recorded_at
    ON job_attempts(recorded_at);

CREATE INDEX IF NOT EXISTS idx_jobs_status
    ON jobs(status);

CREATE INDEX IF NOT EXISTS idx_jobs_completed_at
    ON jobs(completed_at);