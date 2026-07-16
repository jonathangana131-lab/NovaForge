#!/usr/bin/env perl
use strict;
use warnings;
use POSIX qw(setsid);

my ($pid_path, $mode) = @ARGV;
die "usage: timeout-process-tree-helper.pl <pid-path> <grouped|escaped>\n"
    unless defined $pid_path && defined $mode && $mode =~ /\A(?:grouped|escaped)\z/;

$| = 1;
for my $signal_name (qw(HUP INT QUIT TERM)) {
    $SIG{$signal_name} = "IGNORE";
}

sub record_pid {
    my ($role) = @_;
    open my $fh, ">>", $pid_path or die "open $pid_path failed: $!\n";
    print {$fh} "$$ $role\n";
    close $fh or die "close $pid_path failed: $!\n";
}

record_pid("root");
print "helper-ready root=$$\n";

my $child_pid = fork();
die "fork failed: $!\n" unless defined $child_pid;
if ($child_pid == 0) {
    if ($mode eq "escaped") {
        setsid() or die "escaped child setsid failed: $!\n";
    }
    record_pid("child");

    my $grandchild_pid = fork();
    die "fork failed: $!\n" unless defined $grandchild_pid;
    if ($grandchild_pid == 0) {
        record_pid("grandchild");
        sleep 300;
        exit 0;
    }

    sleep 300;
    exit 0;
}

sleep 300;
exit 0;
