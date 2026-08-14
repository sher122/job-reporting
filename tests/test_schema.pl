#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use DBI;
use FindBin qw($Bin);
use File::Temp qw(tempfile);
use File::Spec;


# ============================================================
# Locate schema
# ============================================================

my $project_root = File::Spec->catdir(
    $Bin,
    '..'
);

my $schema_file = File::Spec->catfile(
    $project_root,
    'schema.sql'
);


# ============================================================
# Test 1: schema exists
# ============================================================

ok(
    -f $schema_file,
    'schema.sql exists'
);


# ============================================================
# Read schema
# ============================================================

open my $fh, '<', $schema_file
    or die "Cannot open $schema_file: $!";

local $/;

my $schema = <$fh>;

close $fh;


ok(
    length($schema) > 0,
    'schema.sql is not empty'
);


# ============================================================
# Remove SQL comment lines before splitting statements.
#
# Important:
# Comment blocks may appear immediately before CREATE TABLE
# or CREATE INDEX statements. Removing them first prevents the
# entire SQL statement from being accidentally discarded.
# ============================================================

$schema =~ s/^\s*--.*(?:\r?\n|$)//mg;


# ============================================================
# Create temporary SQLite database
#
# The test never modifies the real project database.
# ============================================================

my ($temp_fh, $db_file) = tempfile(
    'job_reporting_XXXX',
    SUFFIX => '.db',
    UNLINK => 1
);

close $temp_fh;


# ============================================================
# Connect to SQLite
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
    $dbh,
    'SQLite database connection succeeds'
);


# ============================================================
# Execute schema statements
# ============================================================

my @statements = split(
    /;\s*(?:\r?\n|$)/,
    $schema
);

for my $statement (@statements) {

    $statement =~ s/^\s+//;
    $statement =~ s/\s+$//;

    next if $statement eq '';

    my $success = eval {
        $dbh->do($statement);
        1;
    };

    ok(
        $success,
        'Schema statement executes successfully'
    );

    if (!$success) {
        diag($@);
    }
}


# ============================================================
# Verify jobs table
# ============================================================

my ($jobs_table) = $dbh->selectrow_array(
    q{
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
          AND name = 'jobs'
    }
);

ok(
    defined $jobs_table,
    'jobs table exists'
);


# ============================================================
# Verify job_attempts table
# ============================================================

my ($attempts_table) = $dbh->selectrow_array(
    q{
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
          AND name = 'job_attempts'
    }
);

ok(
    defined $attempts_table,
    'job_attempts table exists'
);


# ============================================================
# Verify jobs columns
# ============================================================

my $job_columns = $dbh->selectall_arrayref(
    q{
        PRAGMA table_info(jobs)
    }
);

my %job_column_names = map {
    $_->[1] => 1
} @$job_columns;

for my $column (
    qw(
        job_id
        priority
        type
        status
        total_attempts
        created_at
        completed_at
    )
) {
    ok(
        $job_column_names{$column},
        "jobs table contains column: $column"
    );
}


# ============================================================
# Verify job_attempts columns
# ============================================================

my $attempt_columns = $dbh->selectall_arrayref(
    q{
        PRAGMA table_info(job_attempts)
    }
);

my %attempt_column_names = map {
    $_->[1] => 1
} @$attempt_columns;

for my $column (
    qw(
        id
        job_id
        attempt
        status
        priority
        type
        recorded_at
    )
) {
    ok(
        $attempt_column_names{$column},
        "job_attempts table contains column: $column"
    );
}


# ============================================================
# Verify status constraints only contain real statuses
# ============================================================

my ($jobs_sql) = $dbh->selectrow_array(
    q{
        SELECT sql
        FROM sqlite_master
        WHERE type = 'table'
          AND name = 'jobs'
    }
);

unlike(
    $jobs_sql,
    qr/'INVALID'/,
    'jobs table does not contain unreachable INVALID status'
);


my ($attempts_sql) = $dbh->selectrow_array(
    q{
        SELECT sql
        FROM sqlite_master
        WHERE type = 'table'
          AND name = 'job_attempts'
    }
);

unlike(
    $attempts_sql,
    qr/'INVALID'/,
    'job_attempts table does not contain unreachable INVALID status'
);


# ============================================================
# Verify unique(job_id, attempt)
# ============================================================

my $indexes = $dbh->selectall_arrayref(
    q{
        PRAGMA index_list(job_attempts)
    }
);

my $has_unique_index = 0;

for my $index (@$indexes) {

    my ($index_name, $unique) = (
        $index->[1],
        $index->[2]
    );

    next unless $unique;

    my $index_columns = $dbh->selectall_arrayref(
        "PRAGMA index_info('$index_name')"
    );

    my @columns = map {
        $_->[2]
    } @$index_columns;

    if (
        @columns == 2
        && $columns[0] eq 'job_id'
        && $columns[1] eq 'attempt'
    ) {
        $has_unique_index = 1;
        last;
    }
}

ok(
    $has_unique_index,
    'job_attempts has unique(job_id, attempt) constraint'
);


# ============================================================
# Clean shutdown
# ============================================================

$dbh->disconnect;


done_testing();