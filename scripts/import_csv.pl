#!/usr/bin/perl

use strict;
use warnings;

use DBI;
use FindBin qw($Bin);
use File::Spec;

# ============================================================
# Configuration
# ============================================================

my $PROJECT_ROOT = File::Spec->catdir(
    $Bin,
    '..'
);

my $DEFAULT_CSV = File::Spec->catfile(
    $PROJECT_ROOT,
    '..',
    'job-automation',
    'logs',
    'job_results.csv'
);

my $DEFAULT_DB = File::Spec->catfile(
    $PROJECT_ROOT,
    'db',
    'job_reporting.db'
);

my $SCHEMA_FILE = File::Spec->catfile(
    $PROJECT_ROOT,
    'schema.sql'
);

# ============================================================
# CSV parser
#
# Supports:
#   normal fields
#   quoted fields
#   commas inside quoted fields
#   escaped double quotes
#   empty fields
# ============================================================

sub parse_csv_line {
    my ($line) = @_;

    my @fields;
    my $field = '';
    my $in_quotes = 0;

    my @characters = split //, $line;

    for (my $i = 0; $i < @characters; $i++) {

        my $char = $characters[$i];

        if ($in_quotes) {

            if ($char eq '"') {

                # Escaped double quote: ""
                if (
                    $i + 1 < @characters
                    && $characters[$i + 1] eq '"'
                ) {
                    $field .= '"';
                    $i++;
                }
                else {
                    $in_quotes = 0;
                }
            }
            else {
                $field .= $char;
            }
        }
        else {

            if ($char eq '"') {
                $in_quotes = 1;
            }
            elsif ($char eq ',') {
                push @fields, $field;
                $field = '';
            }
            else {
                $field .= $char;
            }
        }
    }

    die "Malformed CSV row: unterminated quoted field\n"
        if $in_quotes;

    push @fields, $field;

    return \@fields;
}

# ============================================================
# Read schema
# ============================================================

sub read_schema {
    my ($file) = @_;

    open my $fh, '<', $file
        or die "Cannot open schema file $file: $!";

    local $/;
    my $schema = <$fh>;

    close $fh
        or die "Cannot close schema file $file: $!";

    return $schema;
}

# ============================================================
# Execute schema
#
# Remove SQL comment lines before splitting statements.
# ============================================================

sub initialize_schema {
    my ($dbh, $schema) = @_;

    $schema =~ s/^\s*--.*(?:\r?\n|$)//mg;

    my @statements = split(
        /;\s*(?:\r?\n|$)/,
        $schema
    );

    for my $statement (@statements) {

        $statement =~ s/^\s+//;
        $statement =~ s/\s+$//;

        next if $statement eq '';

        $dbh->do($statement);
    }
}

# ============================================================
# Connect to SQLite
# ============================================================

sub connect_database {
    my ($db_file) = @_;

    my $parent_dir = $db_file;

    $parent_dir =~ s/[\/\\][^\/\\]+$//;

    if (!-d $parent_dir) {

        mkdir $parent_dir
            or die "Cannot create database directory $parent_dir: $!";
    }

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$db_file",
        '',
        '',
        {
            RaiseError      => 1,
            AutoCommit      => 1,
            sqlite_unicode  => 1,
        }
    );

    # Explicitly enable foreign-key enforcement.
    $dbh->do('PRAGMA foreign_keys = ON');

    return $dbh;
}

# ============================================================
# Normalize timestamp
#
# Project 1 writes timestamps in Perl's localtime format:
#
#   Sun Aug 16 12:06:28 2026
#
# SQLite/reporting uses:
#
#   2026-08-16 12:06:28
# ============================================================

sub normalize_timestamp {
    my ($timestamp) = @_;

    return undef
        unless defined $timestamp && length $timestamp;

    # --------------------------------------------------------
    # Already-normalized SQLite format:
    #
    # 2026-08-16 12:06:28
    # --------------------------------------------------------

    if (
        $timestamp =~
        /\A
        (\d{4})-
        (\d{2})-
        (\d{2})
        \s+
        (\d{2}):(\d{2}):(\d{2})
        \z
        /x
    ) {
        return $timestamp;
    }

    # --------------------------------------------------------
    # ISO-8601 format used by test fixtures:
    #
    # 2026-08-14T10:00:00
    # --------------------------------------------------------

    if (
        $timestamp =~
        /\A
        (\d{4})-
        (\d{2})-
        (\d{2})
        T
        (\d{2}):(\d{2}):(\d{2})
        \z
        /x
    ) {
        return sprintf(
            "%04d-%02d-%02d %02d:%02d:%02d",
            $1,
            $2,
            $3,
            $4,
            $5,
            $6
        );
    }

    # --------------------------------------------------------
    # Perl localtime format produced by Project 1:
    #
    # Sun Aug 16 12:06:28 2026
    # --------------------------------------------------------

    my %months = (
        Jan => '01',
        Feb => '02',
        Mar => '03',
        Apr => '04',
        May => '05',
        Jun => '06',
        Jul => '07',
        Aug => '08',
        Sep => '09',
        Oct => '10',
        Nov => '11',
        Dec => '12',
    );

    if (
        $timestamp =~
        /\A
        \w{3}\s+
        (\w{3})\s+
        (\d{1,2})\s+
        (\d{2}):(\d{2}):(\d{2})\s+
        (\d{4})
        \z
        /x
    ) {
        my (
            $month,
            $day,
            $hour,
            $minute,
            $second,
            $year
        ) = (
            $1,
            $2,
            $3,
            $4,
            $5,
            $6
        );

        die "Invalid timestamp month: $month\n"
            unless exists $months{$month};

        return sprintf(
            "%04d-%s-%02d %02d:%02d:%02d",
            $year,
            $months{$month},
            $day,
            $hour,
            $minute,
            $second
        );
    }

    die "Invalid timestamp format: $timestamp\n";
}

# ============================================================
# Parse and validate one CSV row
#
# Expected columns:
#
#   timestamp,job_id,priority,type,attempt,status
# ============================================================

sub parse_job_row {
    my ($line, $line_number) = @_;

    my $fields = parse_csv_line($line);

    die "Invalid CSV row at line $line_number: expected 6 fields\n"
        unless @$fields == 6;

    my (
        $timestamp,
        $job_id,
        $priority,
        $type,
        $attempt,
        $status
    ) = @$fields;

    die "Invalid CSV row at line $line_number: missing job_id\n"
        unless defined $job_id
        && $job_id ne '';

    die "Invalid CSV row at line $line_number: invalid priority\n"
        unless defined $priority
        && $priority =~ /\A(?:critical|high|medium|low)\z/;

    die "Invalid CSV row at line $line_number: missing type\n"
        unless defined $type
        && $type ne '';

    die "Invalid CSV row at line $line_number: invalid attempt\n"
        unless defined $attempt
        && $attempt =~ /\A[1-9][0-9]*\z/;

    die "Invalid CSV row at line $line_number: invalid status\n"
        unless defined $status
        && $status =~ /\A(?:SUCCESS|FAILURE)\z/;

    die "Invalid CSV row at line $line_number: missing timestamp\n"
        unless defined $timestamp
        && $timestamp ne '';

    # Normalize the timestamp before the row enters the database.
    my $normalized_timestamp = normalize_timestamp($timestamp);

    return {
        timestamp => $normalized_timestamp,
        job_id    => $job_id,
        priority  => $priority,
        type      => $type,
        attempt   => int($attempt),
        status    => $status,
    };
}

# ============================================================
# Read CSV
# ============================================================

sub read_csv {
    my ($csv_file) = @_;

    open my $fh, '<', $csv_file
        or die "Cannot open CSV file $csv_file: $!";

    my @rows;
    my $line_number = 0;

    while (my $line = <$fh>) {

        $line_number++;

        $line =~ s/\r?\n\z//;

        next if $line eq '';

        # Header
        if ($line_number == 1) {

            my $expected_header =
                'timestamp,job_id,priority,type,attempt,status';

            die "Invalid CSV header in $csv_file\n"
                unless $line eq $expected_header;

            next;
        }

        push @rows,
            parse_job_row(
                $line,
                $line_number
            );
    }

    close $fh
        or die "Cannot close CSV file $csv_file: $!";

    return \@rows;
}

# ============================================================
# Reset database contents
#
# Transaction ownership belongs to import_csv().
# ============================================================

sub reset_database {
    my ($dbh) = @_;

    # Child rows must be deleted first because of the
    # foreign-key relationship.
    $dbh->do(
        'DELETE FROM job_attempts'
    );

    $dbh->do(
        'DELETE FROM jobs'
    );
}

# ============================================================
# Group attempts by job
# ============================================================

sub build_jobs {
    my ($rows) = @_;

    my %jobs;

    for my $row (@$rows) {

        my $job_id = $row->{job_id};

        push @{ $jobs{$job_id} }, $row;
    }

    return \%jobs;
}
# Import strategy:
# Each import performs a complete database reload inside a transaction.
# This makes repeated imports of the same CSV idempotent.
#
# Duplicate (job_id, attempt) rows within a single CSV are not silently
# ignored. The UNIQUE constraint rejects them and the transaction rolls
# back, so the entire import fails rather than partially applying data.
# ============================================================
# Insert logical jobs
#
# The final status is the status of the highest-numbered
# attempt.
#
# created_at = first attempt timestamp
# completed_at = final attempt timestamp
# ============================================================

sub insert_jobs {
    my ($dbh, $jobs) = @_;

    my $statement = $dbh->prepare(
        q{
            INSERT INTO jobs (
                job_id,
                priority,
                type,
                status,
                total_attempts,
                created_at,
                completed_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
        }
    );

    for my $job_id (sort keys %$jobs) {

        my @attempts = sort {
            $a->{attempt} <=> $b->{attempt}
        } @{ $jobs->{$job_id} };

        my $first = $attempts[0];
        my $final = $attempts[-1];

        $statement->execute(
            $job_id,
            $final->{priority},
            $final->{type},
            $final->{status},
            scalar @attempts,
            $first->{timestamp},
            $final->{timestamp}
        );
    }
}

# ============================================================
# Insert individual attempt records
# ============================================================

sub insert_attempts {
    my ($dbh, $rows) = @_;

    my $statement = $dbh->prepare(
        q{
            INSERT INTO job_attempts (
                job_id,
                attempt,
                status,
                priority,
                type,
                recorded_at
            )
            VALUES (?, ?, ?, ?, ?, ?)
        }
    );

    for my $row (@$rows) {

        $statement->execute(
            $row->{job_id},
            $row->{attempt},
            $row->{status},
            $row->{priority},
            $row->{type},
            $row->{timestamp}
        );
    }
}

# ============================================================
# Import CSV into SQLite
#
# The complete database reload is atomic:
#
#   BEGIN
#      delete old data
#      insert jobs
#      insert attempts
#   COMMIT
#
# If anything fails:
#
#   ROLLBACK
# ============================================================

sub import_csv {
    my ($csv_file, $db_file) = @_;

    print "Starting CSV import\n";
    print "CSV file: $csv_file\n";
    print "Database: $db_file\n";

    die "CSV file does not exist: $csv_file\n"
        unless -f $csv_file;

    my $schema = read_schema(
        $SCHEMA_FILE
    );

    my $rows = read_csv(
        $csv_file
    );

    print "Loaded " . scalar(@$rows) . " CSV rows\n";

    my $dbh = connect_database(
        $db_file
    );

    my $transaction_started = 0;

    eval {

        initialize_schema(
            $dbh,
            $schema
        );

        $dbh->begin_work;
        $transaction_started = 1;

        # Batch-reload model:
        # the database represents the current CSV snapshot.
        reset_database(
            $dbh
        );

        # Build the parent records first.
        my $jobs = build_jobs(
            $rows
        );

        # jobs must exist before job_attempts because
        # job_attempts.job_id references jobs.job_id.
        insert_jobs(
            $dbh,
            $jobs
        );

        # Insert the child attempt records.
        insert_attempts(
            $dbh,
            $rows
        );

        $dbh->commit;
        $transaction_started = 0;

        1;

    } or do {

        my $error = $@;

        if ($transaction_started) {
            eval {
                $dbh->rollback;
            };
        }

        eval {
            $dbh->disconnect;
        };

        die $error;
    };

    $dbh->disconnect;

    my $job_count = scalar keys %{
        build_jobs($rows)
    };

    print "Imported attempts: " . scalar(@$rows) . "\n";
    print "Imported jobs:     $job_count\n";
    print "Import completed successfully.\n";

    return 0;
}

# ============================================================
# Programmatic entry point
#
# Arguments:
#   1. CSV file
#   2. SQLite database
# ============================================================

sub main {
    my @args = @_;

    my $csv_file = $args[0] // $DEFAULT_CSV;
    my $db_file  = $args[1] // $DEFAULT_DB;

    return import_csv(
        $csv_file,
        $db_file
    );
}

# ============================================================
# Script entry point
# ============================================================

unless (caller) {

    my $exit_code = eval {
        main(@ARGV);
    };

    if ($@) {

        print STDERR "Import error: $@";

        exit 2;
    }

    exit $exit_code;
}

1;