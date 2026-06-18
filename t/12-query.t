use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'r', kind => 'function', name => 'run',  qualified_name => 'P::run',  file_path => 'f', start_line => 2 });
$s->insert_node({ id => 'h', kind => 'function', name => 'help', qualified_name => 'P::help', file_path => 'f', start_line => 5 });
$s->insert_edge({ source => 'r', target => 'h', kind => 'calls', provenance => 'static' });

my $q = App::PerlGraph::Query->new(store => $s);
is [$q->search('run')]->[0]{id}, 'r', 'search';
is [$q->callees('P::run')]->[0]{qualified_name}, 'P::help', 'callees';
is [$q->callers('P::help')]->[0]{qualified_name}, 'P::run', 'callers';
ok( (grep { $_->{id} eq 'h' } $q->impact('P::run')) == 0, 'impact walks upstream (help has no callers)' );
ok( (grep { $_->{id} eq 'r' } $q->impact('P::help')), 'impact of help includes run' );

my $md = App::PerlGraph::Format::callers('P::help', [$q->callers('P::help')]);
like $md, qr/P::run/, 'format mentions caller';
like $md, qr/f:2/,   'format shows file:line';
done_testing;
