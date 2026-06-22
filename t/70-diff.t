use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Diff;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";
skip_all "git unavailable" unless eval { my $v = `git --version 2>/dev/null`; $? == 0 && $v =~ /git/ };

my $dir = tempdir;
my @gc = ('git', '-C', "$dir");
$dir->child('lib')->mkpath;
# v1 (committed): foo($x), bar (public), _priv (private)
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub foo (\$x) { 1 }\nsub bar { 2 }\nsub _priv { 3 }\n1;\n");
system @gc, 'init', '-q'; system @gc, 'config', 'user.email', 't@t'; system @gc, 'config', 'user.name', 't';
system @gc, 'add', '-A'; system @gc, 'commit', '-qm', 'v1';
# working tree: change foo's signature, drop bar, add baz
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub foo (\$x, \$y) { 1 }\nsub baz { 4 }\nsub _priv { 3 }\n1;\n");

my $d = App::PerlGraph::Diff->new(root => "$dir", ref => 'HEAD', parser => $parser)->diff;

is   [ map { $_->{qualified_name} } @{ $d->{added} } ],   ['A::baz'], 'added: baz';
is   [ map { $_->{qualified_name} } @{ $d->{removed} } ], ['A::bar'], 'removed: bar';
is   [ map { $_->{new}{qualified_name} } @{ $d->{changed} } ], ['A::foo'], 'changed: foo (signature)';
ok  !(grep { $_->{qualified_name} =~ /_priv/ } @{ $d->{added} }, @{ $d->{removed} }), 'unchanged private sub not reported';

# breaking: a removed/changed PUBLIC symbol; bar removal + foo sig change are breaking
ok  $d->{removed}[0]{_breaking},    'a removed public sub is flagged breaking';
ok  $d->{changed}[0]{_breaking},    'a public signature change is flagged breaking';

# format
my $txt = App::PerlGraph::Format::diff($d, 'HEAD');
like $txt, qr/\+ `A::baz`/,        'format: added marker';
like $txt, qr/- `A::bar`.*break/i, 'format: removed + breaking';
like $txt, qr/A::foo.*->/,         'format: signature change shows old -> new';
like App::PerlGraph::Format::diff({ added => [], removed => [], changed => [] }, 'HEAD'), qr/no .*changes/i, 'format: empty diff';

# a whole file added vs a whole file deleted between the ref and the working tree
$dir->child('lib/B.pm')->spew_utf8("package B;\nsub kept { 1 }\n1;\n");
system @gc, 'add', '-A'; system @gc, 'commit', '-qm', 'v2';               # HEAD: A.pm + B.pm
$dir->child('lib/C.pm')->spew_utf8("package C;\nsub fresh { 1 }\n1;\n");  # new file
$dir->child('lib/B.pm')->remove;                                          # deleted file
system @gc, 'add', '-A'; system @gc, 'commit', '-qm', 'v3';
my $d2 = App::PerlGraph::Diff->new(root => "$dir", ref => 'HEAD~1', parser => $parser)->diff;
ok +(grep { $_->{qualified_name} eq 'C::fresh' } @{ $d2->{added} }),  'a file added since the ref: its symbols are all "added"';
my ($gone) = grep { $_->{qualified_name} eq 'B::kept' } @{ $d2->{removed} };
ok $gone,              'a file deleted since the ref: its symbols are all "removed"';
ok $gone->{_breaking}, '... and flagged breaking (public)';

# non-ASCII identifiers: the working-tree read must use the same (raw byte) encoding
# as git->show, else a unicode sub name keys differently on each side and an
# *unchanged* sub falsely shows up as removed+added.
{
    my $u = tempdir; my @ug = ('git', '-C', "$u"); $u->child('lib')->mkpath;
    $u->child('lib/U.pm')->spew_utf8("package U;\nsub caf\x{e9} { 1 }\nsub ascii { 2 }\n1;\n");
    system @ug, 'init', '-q'; system @ug, 'config', 'user.email', 't@t'; system @ug, 'config', 'user.name', 't';
    system @ug, 'add', '-A'; system @ug, 'commit', '-qm', 'v1';
    $u->child('lib/U.pm')->spew_utf8("package U;\nsub caf\x{e9} { 1 }\nsub ascii (\$x) { 2 }\n1;\n");   # change only the ASCII sub
    my $du = App::PerlGraph::Diff->new(root => "$u", ref => 'HEAD', parser => $parser)->diff;
    ok !(grep { ($_->{qualified_name} // '') =~ /caf/ } @{ $du->{added} }, @{ $du->{removed} }),
       'an unchanged non-ASCII sub is not falsely added/removed (working-tree read matches git->show bytes)';
}

done_testing;
