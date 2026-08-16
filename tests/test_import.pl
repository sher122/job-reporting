#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use DBI;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;

# ============================================================
# Load importer
# ============================================================

require "$Bin/../scripts/import_csv.pl";

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
# Includes:
# - normal job
# - retried job
# - comma-containing type
# - ISO timestamp format
# ============================================================

open my $fh, '>', $csv_file
    or die "Cannot create test CSV: $!";

print $fh <<'CSV';
timestamp,job_id,priority,type,attempt,status
2026-08-14T10:00:00,TEST-001,critical,etch,1,SUCCESS
2026-08-14T10:01:00,TEST-002,high,"etch, plasma",1,FAILURE
2026-08-14T10:02:00,TEST-002,high,"etch, plasma",2,FAILURE
2026-08-14T10:03:00,TEST-002,high,"etch, plasma",3,SUCCESS
2026-08-14T10:04:00,TEST-003,medium,clean,1,SUCCESS
2026-08-14T10:05:00,TEST-004,low,inspection,1,SUCCESS
2026-08-14T10:06:00,TEST-004,low,inspection,2,SUCCESS
CSV

close $fh
    or die "Cannot close test CSV: $!";

# ============================================================
# Test 1:
# CSV import succeeds
# ============================================================

my $exit_code = eval {
    import_csv(
        $csv_file,
        $db_file
    );
};

ok(
    !$@,
    'CSV import succeeds'
);

# ============================================================
# Connect to test DB
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

ok(
    defined $dbh,
    'Test database connection succeeds'
);

# ============================================================
# Test 2:
# All attempts imported
# ============================================================

my ($attempt_count) =
    $dbh->selectrow_array(
        'SELECT COUNT(*) FROM job_attempts'
    );

is(
    $attempt_count,
    7,
    'All CSV attempts are imported'
);

# ============================================================
# Test 3:
# Logical jobs created
# ============================================================

my ($job_count) =
    $dbh->selectrow_array(
        'SELECT COUNT(*) FROM jobs'
    );

is(
    $job_count,
    4,
    'Logical jobs are created'
);

# ============================================================
# Test 4:
# Final status comes from highest attempt
# ============================================================

my ($final_status) =
    $dbh->selectrow_array(
        q{
            SELECT status
            FROM jobs
            WHERE job_id = 'TEST-002'
        }
    );

is(
    $final_status,
    'SUCCESS',
    'Final status comes from highest attempt'
);

# ============================================================
# Test 5:
# Total attempts
# ============================================================

my ($total_attempts) =
    $dbh->selectrow_array(
        q{
            SELECT total_attempts
            FROM jobs
            WHERE job_id = 'TEST-002'
        }
    );

is(
    $total_attempts,
    3,
    'Total attempts are calculated correctly'
);

# ============================================================
# Test 6:
# Retried job succeeds
# ============================================================

is(
    $final_status,
    'SUCCESS',
    'Retried job final status is SUCCESS'
);

# ============================================================
# Test 7:
# Retried job has three attempts
# ============================================================

my ($retry_attempt_count) =
    $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM job_attempts
            WHERE job_id = 'TEST-002'
        }
    );

is(
    $retry_attempt_count,
    3,
    'Retried job has three attempts'
);

# ============================================================
# Test 8:
# Comma-containing type survives import
# ============================================================

my ($type) =
    $dbh->selectrow_array(
        q{
            SELECT type
            FROM jobs
            WHERE job_id = 'TEST-002'
        }
    );

is(
    $type,
    'etch, plasma',
    'Comma-containing type is preserved'
);

# ============================================================
# Test 9:
# created_at comes from first attempt
# ============================================================

my ($created_at) =
    $dbh->selectrow_array(
        q{
            SELECT created_at
            FROM jobs
            WHERE job_id = 'TEST-002'
        }
    );

is(
    $created_at,
    '2026-08-14 10:01:00',
    'created_at comes from first attempt'
);

# ============================================================
# Test 10:
# completed_at comes from final attempt
# ============================================================

my ($completed_at) =
    $dbh->selectrow_array(
        q{
            SELECT completed_at
            FROM jobs
            WHERE job_id = 'TEST-002'
        }
    );

is(
    $completed_at,
    '2026-08-14 10:03:00',
    'completed_at comes from final attempt'
);

# ============================================================
# Test 11:
# ISO timestamp is normalized
# ============================================================

is(
    normalize_timestamp(
        '2026-08-14T10:00:00'
    ),
    '2026-08-14 10:00:00',
    'ISO timestamp is normalized'
);

# ============================================================
# Test 12:
# Project 1 Perl timestamp is normalized
# ============================================================

is(
    normalize_timestamp(
        'Sun Aug 16 12:06:28 2026'
    ),
    '2026-08-16 12:06:28',
    'Project 1 timestamp is normalized'
);

# ============================================================
# Test 13:
# SQLite timestamp remains unchanged
# ============================================================

is(
    normalize_timestamp(
        '2026-08-16 12:06:28'
    ),
    '2026-08-16 12:06:28',
    'SQLite timestamp remains unchanged'
);

# ============================================================
# Test 14:
# Second import succeeds
#
# Batch-reload model means the existing database is replaced
# by the current CSV snapshot.
# ============================================================

my $second_import_ok = eval {
    import_csv(
        $csv_file,
        $db_file
    );

    1;
};

ok(
    $second_import_ok,
    'Second import succeeds'
);

# ============================================================
# Test 15:
# Second import does not duplicate attempts
# ============================================================

($attempt_count) =
    $dbh->selectrow_array(
        'SELECT COUNT(*) FROM job_attempts'
    );

is(
    $attempt_count,
    7,
    'Second import does not duplicate attempts'
);

# ============================================================
# Test 16:
# Second import does not duplicate jobs
# ============================================================

($job_count) =
    $dbh->selectrow_array(
        'SELECT COUNT(*) FROM jobs'
    );

is(
    $job_count,
    4,
    'Second import does not duplicate jobs'
);

# ============================================================
# Test 17:
# Database uniqueness constraint rejects duplicate attempt
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
                'TEST-002',
                1,
                'SUCCESS',
                'high',
                'etch, plasma',
                '2026-08-14 10:00:00'
            )
        }
    );

    1;
}
or do {
    $duplicate_error = $@;
};

like(
    $duplicate_error,
    qr/UNIQUE constraint failed/i,
    'Duplicate job attempt is rejected'
);

$dbh->disconnect();

done_testing();