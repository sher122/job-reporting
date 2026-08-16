#!/usr/bin/perl

use strict;
use warnings;

use DBI;
use FindBin qw($Bin);

my $database_file = "$Bin/../db/job_reporting.db";

my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$database_file",
    "",
    "",
    {
        RaiseError => 1,
        AutoCommit => 1,
    }
);

print "Database: $database_file\n\n";

my ($total_jobs) = $dbh->selectrow_array(
    "SELECT COUNT(*) FROM jobs"
);

my ($success_jobs) = $dbh->selectrow_array(
    "SELECT COUNT(*) FROM jobs WHERE status = 'SUCCESS'"
);

my ($failed_jobs) = $dbh->selectrow_array(
    "SELECT COUNT(*) FROM jobs WHERE status = 'FAILURE'"
);

my ($pending_jobs) = $dbh->selectrow_array(
    "SELECT COUNT(*) FROM jobs WHERE status = 'PENDING'"
);

my ($total_attempts) = $dbh->selectrow_array(
    "SELECT COUNT(*) FROM job_attempts"
);

print "Total jobs:     $total_jobs\n";
print "Successful:     $success_jobs\n";
print "Failed:         $failed_jobs\n";
print "Pending:        $pending_jobs\n";
print "Total attempts: $total_attempts\n";
print "\n";

print "Job records:\n";
print "------------------------------------------------------------\n";

my $sth = $dbh->prepare(
    q{
        SELECT
            job_id,
            status,
            created_at,
            completed_at,
            total_attempts
        FROM jobs
        ORDER BY job_id
    }
);

$sth->execute();

while (my $row = $sth->fetchrow_hashref) {
    printf "%-10s | %-8s | attempts=%d | created=%s | completed=%s\n",
        $row->{job_id},
        $row->{status},
        $row->{total_attempts},
        defined $row->{created_at} ? $row->{created_at} : "NULL",
        defined $row->{completed_at} ? $row->{completed_at} : "NULL";
}

print "\nSQLite current local date: ";

my ($today) = $dbh->selectrow_array(
    "SELECT date('now', 'localtime')"
);

print "$today\n";

$dbh->disconnect();

exit 0;