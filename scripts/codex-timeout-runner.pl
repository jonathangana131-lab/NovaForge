#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use POSIX qw(:sys_wait_h setsid);

my ($timeout, $log_path, @command) = @ARGV;
if (!defined $timeout || !defined $log_path || !@command) {
    die "usage: codex-timeout-runner.pl <seconds> <log-path> <command...>\n";
}
if ($timeout !~ /\A\d+\z/ || $timeout <= 0) {
    die "timeout must be a positive integer\n";
}

my $log_dir = dirname($log_path);
if (defined $log_dir && length $log_dir && $log_dir ne '.') {
    make_path($log_dir) unless -d $log_dir;
}

my $command_text = join " ", @command;

my $pid = fork();
die "fork failed: $!\n" unless defined $pid;

if ($pid == 0) {
    setsid() or die "setsid failed: $!\n";
    open STDOUT, ">", $log_path or die "open $log_path failed: $!\n";
    open STDERR, ">&", \*STDOUT or die "redirect stderr failed: $!\n";
    print "[command] $command_text\n";
    exec { $command[0] } @command or die "exec $command[0] failed: $!\n";
}

my $deadline = time + $timeout;
my $term_sent_at;
my $kill_sent = 0;
my $timed_out = 0;

sub append_log {
    my ($message) = @_;
    if (open my $fh, ">>", $log_path) {
        print {$fh} $message;
        close $fh;
    }
}

while (1) {
    my $done = waitpid($pid, WNOHANG);
    if ($done == $pid) {
        my $status = $?;
        exit 142 if $timed_out;
        if (WIFEXITED($status)) {
            exit WEXITSTATUS($status);
        }
        if (WIFSIGNALED($status)) {
            exit 128 + WTERMSIG($status);
        }
        exit 1;
    }
    if ($done == -1) {
        exit 1;
    }

    my $now = time;
    if (!$term_sent_at && $now >= $deadline) {
        append_log("\n[timeout] Command exceeded ${timeout}s; sending TERM to process group $pid.\n");
        kill "TERM", -$pid;
        $term_sent_at = $now;
        $timed_out = 1;
    } elsif ($term_sent_at && !$kill_sent && $now >= $term_sent_at + 5) {
        append_log("[timeout] Command did not exit after TERM; sending KILL to process group $pid.\n");
        kill "KILL", -$pid;
        $kill_sent = 1;
    } elsif ($kill_sent && $term_sent_at && $now >= $term_sent_at + 10) {
        append_log("[timeout] Process group $pid did not reap after KILL; leaving timeout with status 142.\n");
        exit 142;
    }

    sleep 1;
}
