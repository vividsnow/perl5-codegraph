use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Query;

# hand-built: P::run (lines 2-4) calls P::help (defined lines 6-8); the call site
# is recorded at line 3, col 5 (as the resolver stamps it onto the edge).
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'run',  kind => 'function', name => 'run',  qualified_name => 'P::run',
    file_path => 'lib/P.pm', start_line => 2, end_line => 4 });
$s->insert_node({ id => 'help', kind => 'function', name => 'help', qualified_name => 'P::help',
    file_path => 'lib/P.pm', start_line => 6, end_line => 8 });
$s->insert_edge({ source => 'run', target => 'help', kind => 'calls', line => 3, col => 5, provenance => 'static' });

my $q = App::PerlGraph::Query->new(store => $s);

# go-to-definition: cursor on the call (line 3) jumps to help's definition (line 6)
my @d = $q->definition_at('lib/P.pm', 3);
is scalar(@d), 1,                  'one definition at the call site';
is $d[0]{qualified_name}, 'P::help','go-to-def resolves the call to help()';
is $d[0]{start_line}, 6,           '... pointing at its definition line';
is scalar($q->definition_at('lib/P.pm', 7)), 0, 'no definition where there is no call';

# find-references: cursor on help's own name line (6) finds the call site in run
my @r = $q->references_at('lib/P.pm', 6);
is scalar(@r), 1,                       'one reference to help()';
is $r[0]{line}, 3,                      '... at the call-site line';
is $r[0]{caller}{qualified_name}, 'P::run', '... attributed to run()';

# find-references from the call site itself resolves the target, then its refs
is scalar($q->references_at('lib/P.pm', 3)), 1, 'find-refs from a call site finds the target\'s references';

# symbol_at falls back to the enclosing sub when the cursor is in a body line
is $q->symbol_at('lib/P.pm', 4)->{qualified_name}, 'P::run', 'symbol_at: enclosing sub for a body line';
is $q->symbol_at('lib/P.pm', 6)->{qualified_name}, 'P::help','symbol_at: the definition on its name line';

done_testing;
