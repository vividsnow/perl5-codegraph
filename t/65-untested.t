use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

# A.pm: pub() is called by a test; lonely() is public but no test reaches it;
# _hidden() is private (never part of the public surface).
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'pA', kind => 'package', name => 'A', qualified_name => 'A', file_path => 'lib/A.pm', start_line => 1 });
$s->insert_node({ id => 'pub',    kind => 'function', name => 'pub',    qualified_name => 'A::pub',    file_path => 'lib/A.pm', start_line => 2, visibility => 'public' });
$s->insert_node({ id => 'lonely', kind => 'function', name => 'lonely', qualified_name => 'A::lonely', file_path => 'lib/A.pm', start_line => 4, visibility => 'public' });
$s->insert_node({ id => 'hidden', kind => 'function', name => '_hidden', qualified_name => 'A::_hidden', file_path => 'lib/A.pm', start_line => 6, visibility => 'private' });
$s->insert_edge({ source => 'pA', target => $_, kind => 'contains', provenance => 'static' }) for qw(pub lonely hidden);
# a test that calls A::pub
$s->insert_node({ id => 'test', kind => 'function', name => 'main', qualified_name => 'main', file_path => 't/a.t', start_line => 1 });
$s->insert_edge({ source => 'test', target => 'pub', kind => 'calls', provenance => 'static' });

my $q = App::PerlGraph::Query->new(store => $s);
my %u = map { ($_->{qualified_name} => 1) } $q->untested;

ok   $u{'A::lonely'},  'a public sub no test reaches is reported untested';
ok  !$u{'A::pub'},     'a public sub a test calls is NOT reported';
ok  !$u{'A::_hidden'}, 'a private sub is never part of the (un)tested public surface';

# format + the module filter
my $txt = App::PerlGraph::Format::untested([ $q->untested ]);
like $txt, qr/A::lonely/,                       'format lists the untested symbol';
like $txt, qr/untested/i,                        'format names what it is';
like App::PerlGraph::Format::untested([]), qr/_none_/, 'format: nothing untested';
ok +(grep { $_->{qualified_name} eq 'A::lonely' } $q->untested('A')), 'untested(module) scopes to one module';

done_testing;
