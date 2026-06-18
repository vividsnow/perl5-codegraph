use v5.36;
use Test2::V0;
use App::PerlGraph::Source;
use Path::Tiny qw(tempdir);

my $dir = tempdir;
$dir->child('M.pm')->spew_utf8("package M;\nsub hi {\n  return 1;\n}\n1;\n");

my $src = App::PerlGraph::Source::for_node(
    { file_path => 'M.pm', start_line => 2, end_line => 4 }, "$dir");
like $src, qr/sub hi/,   'reads the symbol source';
like $src, qr/return 1/, 'includes body lines';
unlike $src, qr/package M/, 'does not include lines outside the range';

ok !App::PerlGraph::Source::for_node({ file_path => 'M.pm', start_line => undef }, "$dir"),
    'no start_line -> undef (e.g. runtime symtab node)';
ok !App::PerlGraph::Source::for_node({ file_path => 'nope.pm', start_line => 1 }, "$dir"),
    'missing file -> undef';

like App::PerlGraph::Source::for_node({ file_path => 'M.pm', start_line => 0, end_line => 1 }, "$dir"),
    qr/package M/, 'start_line 0 is a real (clamped) line, not treated as absent';
done_testing;
