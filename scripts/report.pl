#!/usr/bin/perl

use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use DBI;

# ============================================================
# Job Reporting CLI
#
# Reports:
#   - Jobs completed today
#   - Average Retry Overhead
#   - Failure rate
#   - Jobs pending
#
# Average Retry Overhead means:
#
#   Average elapsed time between the first and final attempt
#   for jobs whose final status is SUCCESS.
#
# Single-attempt successful jobs therefore contribute 0 seconds.
#
# The current schema does not permit PENDING as a jobs.status
# value, so the pending query currently returns 0 by design.
# ============================================================

# ------------------------------------------------------------
# Database path
# ------------------------------------------------------------

my $db_file = File::Spec->catfile(
    $Bin,
    '..',
    'db',
    'job_reporting.db'
);

# ------------------------------------------------------------
# Connect to SQLite
# ------------------------------------------------------------

die "Database does not exist: $db_file\n"
    unless -f $db_file;

my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$db_file",
    "",
    "",
    {
        RaiseError => 1,
        AutoCommit => 1,
    }
);

# ------------------------------------------------------------
# Jobs completed today
# ------------------------------------------------------------

my ($completed_today) = $dbh->selectrow_array(q{
    SELECT COUNT(*)
    FROM jobs
    WHERE status = 'SUCCESS'
      AND created_at IS NOT NULL
      AND completed_at IS NOT NULL
      AND date(completed_at) = date('now', 'localtime')
});

$completed_today ||= 0;

# ------------------------------------------------------------
# Average Retry Overhead
#
# IMPORTANT:
# Only successful jobs are included.
#
# This keeps this report consistent with report_html.pl.
# ------------------------------------------------------------

my ($average_retry_overhead) = $dbh->selectrow_array(q{
    SELECT AVG(
        (julianday(completed_at) - julianday(created_at))
        * 86400.0
    )
    FROM jobs
    WHERE status = 'SUCCESS'
      AND created_at IS NOT NULL
      AND completed_at IS NOT NULL
});

$average_retry_overhead ||= 0;

# ------------------------------------------------------------
# Failure rate
#
# Failure rate is based on final job status.
# ------------------------------------------------------------

my ($total_jobs) = $dbh->selectrow_array(q{
    SELECT COUNT(*)
    FROM jobs
});

my ($failed_jobs) = $dbh->selectrow_array(q{
    SELECT COUNT(*)
    FROM jobs
    WHERE status = 'FAILURE'
});

$total_jobs ||= 0;
$failed_jobs ||= 0;

my $failure_rate = 0;

if ($total_jobs > 0) {
    $failure_rate =
        ($failed_jobs / $total_jobs) * 100;
}

# ------------------------------------------------------------
# Pending jobs
#
# PENDING is not currently a legal jobs.status value.
# This query is deliberately retained at the reporting layer
# so the report is ready if the schema is extended later.
#
# Under the current schema this always returns 0.
# ------------------------------------------------------------

my ($pending) = $dbh->selectrow_array(q{
    SELECT COUNT(*)
    FROM jobs
    WHERE status = 'PENDING'
});

$pending ||= 0;

# ------------------------------------------------------------
# Close database
# ------------------------------------------------------------

$dbh->disconnect();

# ------------------------------------------------------------
# Display formatting
# ------------------------------------------------------------

my $average_display = sprintf(
    "%.2f seconds",
    $average_retry_overhead
);

my $failure_display = sprintf(
    "%.2f%%",
    $failure_rate
);

# ------------------------------------------------------------
# Output
# ------------------------------------------------------------

print "\n";
print "Job Reporting Dashboard\n";
print "=======================\n";
print "\n";

print "Jobs completed today: $completed_today\n";

print "Average Retry Overhead: $average_display\n";

print "Failure rate:          $failure_display\n";

print "Jobs pending:          $pending\n";

print "\n";

exit 0;