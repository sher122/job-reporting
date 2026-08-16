#!/usr/bin/perl

use strict;
use warnings;

use DBI;
use FindBin qw($Bin);

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

my $project_root = "$Bin/..";
my $database_file = "$project_root/db/job_reporting.db";

# ------------------------------------------------------------
# Database connection
# ------------------------------------------------------------

sub connect_database {
    my ($database_file) = @_;

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$database_file",
        "",
        "",
        {
            RaiseError => 1,
            AutoCommit => 1,
        }
    );

    return $dbh;
}

# ------------------------------------------------------------
# Jobs completed today
#
# A job is considered completed when its final status is SUCCESS.
# The report uses completed_at to determine whether completion
# happened today.
# ------------------------------------------------------------

sub get_completed_today {
    my ($dbh) = @_;

    my ($count) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM jobs
            WHERE status = 'SUCCESS'
              AND date(completed_at) = date('now', 'localtime')
        }
    );

    return $count // 0;
}

# ------------------------------------------------------------
# Average turnaround time
#
# Turnaround time is:
#
# completed_at - created_at
#
# created_at represents the first attempt timestamp.
# completed_at represents the final attempt timestamp.
# ------------------------------------------------------------

sub get_average_turnaround {
    my ($dbh) = @_;

    my ($average) = $dbh->selectrow_array(
        q{
            SELECT AVG(
                (julianday(completed_at) - julianday(created_at))
                * 86400.0
            )
            FROM jobs
            WHERE status = 'SUCCESS'
              AND created_at IS NOT NULL
              AND completed_at IS NOT NULL
        }
    );

    return defined $average ? $average : 0;
}

# ------------------------------------------------------------
# Failure rate
#
# Failure rate is the percentage of logical jobs whose final
# status is FAILURE.
#
# We deliberately calculate this at the jobs level rather than
# counting failed attempts, because a retried job may contain
# several failed attempts but ultimately succeed.
# ------------------------------------------------------------

sub get_failure_rate {
    my ($dbh) = @_;

    my ($rate) = $dbh->selectrow_array(
        q{
            SELECT
                CASE
                    WHEN COUNT(*) = 0 THEN 0
                    ELSE
                        (SUM(CASE WHEN status = 'FAILURE' THEN 1 ELSE 0 END)
                        * 100.0) / COUNT(*)
                END
            FROM jobs
        }
    );

    return defined $rate ? $rate : 0;
}

# ------------------------------------------------------------
# Jobs still pending
#
# Project 1 currently produces SUCCESS or FAILURE final states.
# This query is nevertheless kept at the reporting layer so
# the report correctly handles pending jobs if the schema is
# extended to support them later.
# ------------------------------------------------------------

sub get_pending_jobs {
    my ($dbh) = @_;

    my ($count) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM jobs
            WHERE status = 'PENDING'
        }
    );

    return $count // 0;
}

# ------------------------------------------------------------
# Print report
# ------------------------------------------------------------

sub print_report {
    my ($dbh) = @_;

    my $completed_today = get_completed_today($dbh);
    my $average_turnaround = get_average_turnaround($dbh);
    my $failure_rate = get_failure_rate($dbh);
    my $pending_jobs = get_pending_jobs($dbh);

    print "\n";
    print "Job Reporting Dashboard\n";
    print "=======================\n";
    print "\n";

    print "Jobs completed today: ",
          $completed_today,
          "\n";

    printf "Average turnaround:   %.2f seconds\n",
           $average_turnaround;

    printf "Failure rate:          %.2f%%\n",
           $failure_rate;

    print "Jobs pending:          ",
          $pending_jobs,
          "\n";

    print "\n";
}

# ------------------------------------------------------------
# Application entry point
# ------------------------------------------------------------

sub main {
    my $dbh;

    eval {
        $dbh = connect_database($database_file);

        print_report($dbh);

        1;
    }
    or do {
        my $error = $@ || "Unknown database error";

        chomp $error;

        print STDERR "Application error: $error\n";

        return 2;
    };

    $dbh->disconnect() if $dbh;

    return 0;
}

# ------------------------------------------------------------
# Run only when executed directly.
#
# This allows the file to be required by tests without
# automatically running the application.
# ------------------------------------------------------------

unless (caller) {
    exit main();
}

1;