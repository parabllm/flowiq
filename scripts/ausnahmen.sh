#!/bin/bash
# Counts concurrency and error exceptions per module and checks them (docs/ARCHITEKTUR.md appendix F).
# An exception is `try?` (marker `// try?-ok: <reason>`) or `@unchecked Sendable`, `nonisolated(unsafe)`,
# `@preconcurrency` (marker `// SAFETY: <reason>`), always on the same line, reason at least 15 characters.
# Upper bounds per module come from pruefgrenzen.tsv (rows "ausnahmen <modul> <n>", missing row = 0).
# Usage: scripts/ausnahmen.sh [limits.tsv] [files...]; default all Swift files below Sources/ and Tests/.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
limits="${1:-pruefgrenzen.tsv}"
[ $# -gt 0 ] && shift
[ -f "$limits" ] || { echo "ausnahmen: $limits fehlt"; exit 2; }
if [ $# -eq 0 ]; then set -- $(find Sources Tests -name '*.swift' -type f | sort); fi
exec perl -CSD -Mutf8 -e '
  my ($limits, @files) = @ARGV;
  my (%limit, @order, %count, $fail);
  open(my $l, "<", $limits) or die "ausnahmen: $limits: $!\n";
  while (<$l>) {
    chomp; next if /^#/ || /^\s*$/;
    my ($art, $name, $value) = split /\t/;
    next unless $art eq "ausnahmen";
    die "ausnahmen: ungültige Zeile $name\n" unless defined $value && $value =~ /^\d+$/;
    $limit{$name} = $value; push @order, $name;
  }
  for my $file (@files) {
    my $module = $file =~ m{^Sources/([^/]+)/} ? $1 : "Tests";
    $count{$module} //= 0;
    open(my $f, "<", $file) or die "ausnahmen: $file: $!\n";
    while (my $line = <$f>) {
      my ($code, $comment) = split m{//}, $line, 2;
      $comment //= "";
      my @hits;
      push @hits, ["try?", "try?-ok"] if $code =~ /\btry\?/;
      push @hits, [$1, "SAFETY"] while $code =~ /(\@unchecked Sendable|nonisolated\(unsafe\)|\@preconcurrency)/g;
      for my $hit (@hits) {
        my ($what, $marker) = @$hit;
        $count{$module}++;
        next if $comment =~ /\Q$marker\E:\s*\S.{14,}/;
        print "VERBOTEN: $what ohne // $marker: mit mindestens 15 Zeichen Begründung, $file:$.\n";
        $fail = 1;
      }
    }
    close $f;
  }
  my %seen; my @modules = grep { !$seen{$_}++ } (@order, sort keys %count);
  for my $module (@modules) {
    my ($n, $max) = ($count{$module} // 0, $limit{$module} // 0);
    my $over = $n > $max;
    printf "%-16s %d Ausnahmen, erlaubt %d%s\n", $module, $n, $max, $over ? "  ÜBER DER OBERGRENZE" : "";
    $fail = 1 if $over;
  }
  exit($fail ? 1 : 0);
' "$limits" "$@"
