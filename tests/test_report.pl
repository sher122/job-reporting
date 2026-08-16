#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use DBI;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/../scripts/report.pl";

# ------------------------------------------------------------
# Create an isolated temporary database.
# ------------------------------------------------------------

my $temp_dir = tempdir(CLEANUP => 1);
my $database_file = "$temp_dir/test.db";

my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$database_file",
    "",
    "",
    {
        RaiseError => 1,
        AutoCommit => 1,
    }
);

# ------------------------------------------------------------
# Create the minimal schema required by the reporting queries.
# ------------------------------------------------------------

$dbh->do(q{
    CREATE TABLE jobs (
        job_id       TEXT PRIMARY KEY,
        priority     TEXT NOT NULL,
        type         TEXT NOT NULL,
        status       TEXT NOT NULL,
        total_attempts INTEGER NOT NULL,
        created_at   TEXT,
        completed_at TEXT
    )
});

# ------------------------------------------------------------
# Use fixed timestamps so the test does not depend on
# randomly generated Project 1 data.
#
# JOB-001:
#   Successful today, 10 seconds turnaround.
#
# JOB-002:
#   Successful today, 20 seconds turnaround.
#
# JOB-003:
#   Failed job.
#
# JOB-004:
#   Pending job.
# ------------------------------------------------------------

$dbh->do(
    q{
        INSERT INTO jobs
            (job_id, priority, type, status, total_attempts,
             created_at, completed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    "JOB-001",
    "critical",
    "etch",
    "SUCCESS",
    1,
    "2026-08-16 09:00:00",
    "2026-08-16 09:00:10"
);

$dbh->do(
    q{
        INSERT INTO jobs
            (job_id, priority, type, status, total_attempts,
             created_at, completed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    "JOB-002",
    "high",
    "inspection",
    "SUCCESS",
    2,
    "2026-08-16 10:00:00",
    "2026-08-16 10:00:20"
);

$dbh->do(
    q{
        INSERT INTO jobs
            (job_id, priority, type, status, total_attempts,
             created_at, completed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    "JOB-003",
    "medium",
    "clean",
    "FAILURE",
    3,
    "2026-08-16 11:00:00",
    "2026-08-16 11:00:30"
);

$dbh->do(
    q{
        INSERT INTO jobs
            (job_id, priority, type, status, total_attempts,
             created_at, completed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    "JOB-004",
    "low",
    "deposition",
    "PENDING",
    0,
    "2026-08-16 12:00:00",
    undef
);

# ------------------------------------------------------------
# Test completed jobs.
# ------------------------------------------------------------

is(
    get_completed_today($dbh),
    2,
    "Two successful jobs completed today"
);

# ------------------------------------------------------------
# Test average turnaround.
#
# JOB-001 = 10 seconds
# JOB-002 = 20 seconds
# Average = 15 seconds
#
# Failed jobs are deliberately excluded.
# ------------------------------------------------------------

my $average = get_average_turnaround($dbh);

ok(
    abs($average - 15) < 0.01,
    "Average turnaround is 15 seconds"
);

# ------------------------------------------------------------
# Test failure rate.
#
# 1 failed job / 4 total jobs = 25%
# ------------------------------------------------------------

my $failure_rate = get_failure_rate($dbh);

ok(
    abs($failure_rate - 25) < 0.01,
    "Failure rate is 25 percent"
);

# ------------------------------------------------------------
# Test pending jobs.
# ------------------------------------------------------------

is(
    get_pending_jobs($dbh),
    1,
    "One job is pending"
);

# ------------------------------------------------------------
# Test that report output contains the expected metrics.
# ------------------------------------------------------------

my $output = "";

{
    local *STDOUT;

    open(STDOUT, ">", \$output)
        or die "Cannot capture STDOUT: $!";

    print_report($dbh);
}

like(
    $output,
    qr/Jobs completed today:\s+2/,
    "Report displays completed-job count"
);

like(
    $output,
    qr/Average turnaround:\s+15\.00 seconds/,
    "Report displays average turnaround"
);

like(
    $output,
    qr/Failure rate:\s+25\.00%/,
    "Report displays failure rate"
);

like(
    $output,
    qr/Jobs pending:\s+1/,
    "Report displays pending-job count"
);

$dbh->disconnect();

done_testing();