#!/usr/bin/perl

use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use DBI;
use Getopt::Long qw(GetOptions);

# ============================================================
# HTML Job Reporting Dashboard
#
# Reports:
#   - Jobs completed today
#   - Average Retry Overhead
#   - Failure rate
#   - Jobs pending
#   - Individual job details
#
# Average Retry Overhead means:
#
#   Average elapsed time between the first and final attempt
#   for jobs whose final status is SUCCESS.
#
# Single-attempt successful jobs contribute 0 seconds.
#
# The current schema does not permit PENDING as a jobs.status
# value, so the pending query currently returns 0 by design.
# ============================================================

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

my $default_db = File::Spec->catfile(
    $Bin,
    '..',
    'db',
    'job_reporting.db'
);

my $default_output = File::Spec->catfile(
    $Bin,
    '..',
    'report.html'
);

my $db_file =
    $ENV{JOB_REPORTING_DB} || $default_db;

my $output_file =
    $ENV{JOB_REPORTING_HTML} || $default_output;

# ------------------------------------------------------------
# Command-line options
# ------------------------------------------------------------

GetOptions(
    'db=s'     => \$db_file,
    'output=s' => \$output_file,
)
or die "Invalid command-line options\n";

# ------------------------------------------------------------
# HTML escaping
# ------------------------------------------------------------

sub html_escape {
    my ($value) = @_;

    return '' unless defined $value;

    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;

    return $value;
}

# ------------------------------------------------------------
# Database
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
# SUCCESS ONLY.
#
# This query MUST match scripts/report.pl.
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
# PENDING is intentionally retained as a reporting query.
#
# Under the current schema, PENDING is not a legal status,
# therefore this currently returns 0.
# ------------------------------------------------------------

my ($pending) = $dbh->selectrow_array(q{
    SELECT COUNT(*)
    FROM jobs
    WHERE status = 'PENDING'
});

$pending ||= 0;

# ------------------------------------------------------------
# Job details
# ------------------------------------------------------------

my $job_sth = $dbh->prepare(q{
    SELECT
        job_id,
        priority,
        type,
        status,
        total_attempts,
        created_at,
        completed_at
    FROM jobs
    ORDER BY
        CASE priority
            WHEN 'critical' THEN 1
            WHEN 'high'     THEN 2
            WHEN 'medium'   THEN 3
            WHEN 'low'      THEN 4
            ELSE 5
        END,
        created_at,
        job_id
});

$job_sth->execute();

my $job_rows = '';

while (my $job = $job_sth->fetchrow_hashref) {

    my $status_class;

    if (($job->{status} // '') eq 'SUCCESS') {
        $status_class = 'success';
    }
    elsif (($job->{status} // '') eq 'FAILURE') {
        $status_class = 'failure';
    }
    else {
        $status_class = 'pending';
    }

    my $job_id =
        html_escape($job->{job_id});

    my $priority =
        html_escape($job->{priority});

    my $type =
        html_escape($job->{type});

    my $status =
        html_escape($job->{status});

    my $attempts =
        html_escape($job->{total_attempts});

    my $created_at =
        html_escape($job->{created_at});

    my $completed_at =
        html_escape($job->{completed_at});

    $job_rows .= qq{
        <tr>
            <td>$job_id</td>
            <td>$priority</td>
            <td>$type</td>
            <td>
                <span class="status $status_class">
                    $status
                </span>
            </td>
            <td>$attempts</td>
            <td>$created_at</td>
            <td>$completed_at</td>
        </tr>
    };
}

$job_sth->finish();

$dbh->disconnect();

# ------------------------------------------------------------
# Display values
# ------------------------------------------------------------

my $average_display = sprintf(
    "%.2f sec",
    $average_retry_overhead
);

my $failure_display = sprintf(
    "%.2f%%",
    $failure_rate
);

my $generated_at =
    scalar localtime();

# ------------------------------------------------------------
# HTML template
#
# IMPORTANT:
#
# All dynamic placeholders use {{...}} delimiters.
#
# This prevents a word such as PENDING in normal prose from
# accidentally being treated as a replacement token.
# ------------------------------------------------------------

my $html = <<'HTML';
<!DOCTYPE html>
<html lang="en">

<head>

<meta charset="UTF-8">

<meta
    name="viewport"
    content="width=device-width, initial-scale=1.0"
>

<title>Job Reporting Dashboard</title>

<style>

* {
    box-sizing: border-box;
}

body {
    margin: 0;
    padding: 28px;

    background: #f4f6f8;

    color: #102a43;

    font-family:
        -apple-system,
        BlinkMacSystemFont,
        "Segoe UI",
        Arial,
        sans-serif;
}

.container {
    max-width: 1280px;

    margin: 0 auto;
}

h1 {
    margin: 0;

    font-size: 32px;

    line-height: 1.2;
}

.subtitle {
    margin-top: 8px;

    margin-bottom: 30px;

    color: #52606d;

    font-size: 16px;
}

.metrics {
    display: grid;

    grid-template-columns:
        repeat(4, 1fr);

    gap: 18px;

    margin-bottom: 30px;
}

.metric-card {
    background: white;

    border-radius: 10px;

    padding: 26px;

    box-shadow:
        0 3px 12px
        rgba(16, 42, 67, 0.08);

    min-height: 145px;
}

.metric-label {
    color: #52606d;

    font-size: 14px;

    margin-bottom: 10px;
}

.metric-value {
    color: #102a43;

    font-size: 30px;

    font-weight: 700;
}

.metric-note {
    color: #52606d;

    font-size: 12px;

    margin-top: 8px;

    line-height: 1.35;
}

.card {
    background: white;

    border-radius: 10px;

    padding: 24px;

    box-shadow:
        0 3px 12px
        rgba(16, 42, 67, 0.08);

    overflow-x: auto;
}

.card h2 {
    margin-top: 0;

    margin-bottom: 20px;

    font-size: 24px;
}

table {
    width: 100%;

    border-collapse: collapse;

    min-width: 900px;
}

th {
    text-align: left;

    padding: 14px 12px;

    background: #f8fafc;

    color: #102a43;

    font-size: 13px;

    text-transform: uppercase;

    border-bottom:
        1px solid #d9e2ec;
}

td {
    padding: 13px 12px;

    border-bottom:
        1px solid #d9e2ec;

    font-size: 14px;
}

tr:last-child td {
    border-bottom: none;
}

.status {
    display: inline-block;

    padding: 5px 11px;

    border-radius: 999px;

    font-size: 12px;

    font-weight: 700;
}

.status.success {
    background: #d9fbe5;

    color: #087443;
}

.status.failure {
    background: #ffe3e3;

    color: #b42318;
}

.status.pending {
    background: #fff4cc;

    color: #8a6116;
}

.generated {
    margin-top: 18px;

    color: #52606d;

    font-size: 13px;
}

@media (max-width: 1000px) {

    .metrics {
        grid-template-columns:
            repeat(2, 1fr);
    }

}

@media (max-width: 600px) {

    body {
        padding: 16px;
    }

    .metrics {
        grid-template-columns: 1fr;
    }

    h1 {
        font-size: 26px;
    }

}

</style>

</head>

<body>

<div class="container">

    <h1>
        Job Reporting Dashboard
    </h1>

    <div class="subtitle">
        SQLite-backed reporting for the Project 1 job automation system
    </div>

    <div class="metrics">

        <div class="metric-card">

            <div class="metric-label">
                Jobs Completed Today
            </div>

            <div class="metric-value">
                {{COMPLETED_TODAY}}
            </div>

        </div>


        <div class="metric-card">

            <div class="metric-label">
                Average Retry Overhead
            </div>

            <div class="metric-value">
                {{AVERAGE_RETRY_OVERHEAD}}
            </div>

            <div class="metric-note">
                Time between the first and final attempt
                for successful jobs.
                Single-attempt jobs contribute 0 seconds.
            </div>

        </div>


        <div class="metric-card">

            <div class="metric-label">
                Failure Rate
            </div>

            <div class="metric-value">
                {{FAILURE_RATE}}
            </div>

        </div>


        <div class="metric-card">

            <div class="metric-label">
                Jobs Pending
            </div>

            <div class="metric-value">
                {{PENDING_COUNT}}
            </div>

            <div class="metric-note">
                PENDING is not currently a legal database status.
            </div>

        </div>

    </div>


    <div class="card">

        <h2>
            Job Details
        </h2>

        <table>

            <thead>

                <tr>

                    <th>Job ID</th>

                    <th>Priority</th>

                    <th>Type</th>

                    <th>Status</th>

                    <th>Attempts</th>

                    <th>Created</th>

                    <th>Completed</th>

                </tr>

            </thead>

            <tbody>

                {{JOB_ROWS}}

            </tbody>

        </table>


        <div class="generated">

            Report generated:
            {{GENERATED_AT}}

        </div>

    </div>

</div>

</body>

</html>
HTML

# ------------------------------------------------------------
# Placeholder substitution
# ------------------------------------------------------------

$html =~
    s/\{\{COMPLETED_TODAY\}\}/$completed_today/g;

$html =~
    s/\{\{AVERAGE_RETRY_OVERHEAD\}\}/$average_display/g;

$html =~
    s/\{\{FAILURE_RATE\}\}/$failure_display/g;

$html =~
    s/\{\{PENDING_COUNT\}\}/$pending/g;

$html =~
    s/\{\{JOB_ROWS\}\}/$job_rows/g;

$html =~
    s/\{\{GENERATED_AT\}\}/$generated_at/g;

# ------------------------------------------------------------
# Safety check
#
# No {{PLACEHOLDER}} tokens should remain.
# ------------------------------------------------------------

die "Unresolved HTML template placeholder remains\n"
    if $html =~ /\{\{[A-Z_]+\}\}/;

# ------------------------------------------------------------
# Write HTML report
# ------------------------------------------------------------

open my $out, '>', $output_file
    or die
        "Cannot write HTML report '$output_file': $!";

print {$out} $html;

close $out
    or die
        "Cannot close HTML report '$output_file': $!";

print "HTML report generated: $output_file\n";

exit 0;