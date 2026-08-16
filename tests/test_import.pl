#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use DBI;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Spec;


my $project_root = File::Spec->catdir(
    $Bin,
    '..'
);

my $importer = File::Spec->catfile(
    $project_root,
    'scripts',
    'import_csv.pl'
);

require $importer;


# ============================================================
# Temporary test environment
# ============================================================

my $temp_dir = tempdir(
    CLEANUP => 1
);

my $csv_file = File::Spec->catfile(
    $temp_dir,
    'test_results.csv'
);

my $db_file = File::Spec->catfile(
    $temp_dir,
    'test.db'
);


# ============================================================
# Test CSV
#
# JOB-001:
#   attempt 1 = FAILURE
#   attempt 2 = SUCCESS
#
# JOB-002:
#   attempt 1 = SUCCESS
#
# JOB-003:
#   attempt 1 = FAILURE
#   attempt 2 = FAILURE
#   attempt 3 = SUCCESS
#
# JOB-004:
#   type contains a comma.
# ============================================================

open my $fh, '>', $csv_file
    or die "Cannot create test CSV: $!";

print $fh <<'CSV';
timestamp,job_id,priority,type,attempt,status
2026-08-14T10:00:00,JOB-001,critical,etch,1,FAILURE
2026-08-14T10:01:00,JOB-001,critical,etch,2,SUCCESS
2026-08-14T10:02:00,JOB-002,high,inspection,1,SUCCESS
2026-08-14T10:03:00,JOB-003,medium,deposition,1,FAILURE
2026-08-14T10:04:00,JOB-003,medium,deposition,2,FAILURE
2026-08-14T10:05:00,JOB-003,medium,deposition,3,SUCCESS
2026-08-14T10:06:00,JOB-004,low,"etch, plasma",1,SUCCESS
CSV

close $fh;


# ============================================================
# Test 1:
# Import succeeds.
# ============================================================

is(
    import_csv(
        $csv_file,
        $db_file
    ),
    0,
    'CSV import succeeds'
);


# ============================================================
# Connect to imported database
# ============================================================

my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$db_file",
    '',
    '',
    {
        RaiseError => 1,
        AutoCommit => 1,
    }
);


# ============================================================
# Test 2:
# Every CSV attempt became a database row.
# ============================================================

my ($attempt_count) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM job_attempts'
);

is(
    $attempt_count,
    7,
    'All CSV attempts are imported'
);


# ============================================================
# Test 3:
# Four logical jobs were created.
# ============================================================

my ($job_count) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM jobs'
);

is(
    $job_count,
    4,
    'Logical jobs are created'
);


# ============================================================
# Test 4:
# JOB-001 final status comes from attempt 2.
# ============================================================

my ($status, $attempts) =
    $dbh->selectrow_array(
        q{
            SELECT status, total_attempts
            FROM jobs
            WHERE job_id = 'JOB-001'
        }
    );

is(
    $status,
    'SUCCESS',
    'Final status comes from highest attempt'
);

is(
    $attempts,
    2,
    'Total attempts are calculated correctly'
);


# ============================================================
# Test 5:
# JOB-003 requires three attempts and eventually succeeds.
# ============================================================

($status, $attempts) =
    $dbh->selectrow_array(
        q{
            SELECT status, total_attempts
            FROM jobs
            WHERE job_id = 'JOB-003'
        }
    );

is(
    $status,
    'SUCCESS',
    'Retried job final status is SUCCESS'
);

is(
    $attempts,
    3,
    'Retried job has three attempts'
);


# ============================================================
# Test 6:
# Comma-containing type survives CSV parsing.
# ============================================================

my ($type) = $dbh->selectrow_array(
    q{
        SELECT type
        FROM jobs
        WHERE job_id = 'JOB-004'
    }
);

is(
    $type,
    'etch, plasma',
    'Comma-containing type is preserved'
);


# ============================================================
# Test 7:
# First and final timestamps are derived correctly.
# ============================================================

my ($created_at, $completed_at) =
    $dbh->selectrow_array(
        q{
            SELECT created_at, completed_at
            FROM jobs
            WHERE job_id = 'JOB-003'
        }
    );

is(
    $created_at,
    '2026-08-14T10:03:00',
    'created_at comes from first attempt'
);

is(
    $completed_at,
    '2026-08-14T10:05:00',
    'completed_at comes from final attempt'
);


# ============================================================
# Test 8:
# Running the importer again is idempotent.
# ============================================================

is(
    import_csv(
        $csv_file,
        $db_file
    ),
    0,
    'Second import succeeds'
);


($attempt_count) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM job_attempts'
);

($job_count) = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM jobs'
);

is(
    $attempt_count,
    7,
    'Second import does not duplicate attempts'
);

is(
    $job_count,
    4,
    'Second import does not duplicate jobs'
);


# ============================================================
# Test 9:
# Unique(job_id, attempt) prevents duplicate attempt rows.
# ============================================================

my $duplicate_error;

eval {

    $dbh->do(
        q{
            INSERT INTO job_attempts (
                job_id,
                attempt,
                status,
                priority,
                type,
                recorded_at
            )
            VALUES (
                'JOB-001',
                1,
                'FAILURE',
                'critical',
                'etch',
                '2026-08-14T10:00:00'
            )
        }
    );

    1;

} or do {

    $duplicate_error = $@;
};

ok(
    $duplicate_error,
    'Duplicate job attempt is rejected'
);


$dbh->disconnect;


done_testing();