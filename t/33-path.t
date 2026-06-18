use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;
use App::PerlGraph::CLI;

# --- Query::path over a hand-built graph (precise edge control, no parser needed) ---
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
my %id = (a => 'na', b => 'nb', c => 'nc', d => 'nd', x => 'nx', pkg => 'npkg');
$s->insert_node({ id => $id{$_}, kind => 'function', name => $_, qualified_name => "P::$_", file_path => 'lib/P.pm', start_line => 1 })
    for qw(a b c d x);
$s->insert_node({ id => $id{pkg}, kind => 'package', name => 'P', qualified_name => 'P', file_path => 'lib/P.pm', start_line => 1 });
$s->insert_edge({ source => $id{pkg}, target => $id{a}, kind => 'contains',   provenance => 'static' });
$s->insert_edge({ source => $id{a},   target => $id{b}, kind => 'calls',      provenance => 'static' });
$s->insert_edge({ source => $id{b},   target => $id{c}, kind => 'calls',      provenance => 'static' });
$s->insert_edge({ source => $id{a},   target => $id{c}, kind => 'references', provenance => 'static' });  # direct a->c
$s->insert_edge({ source => $id{c},   target => $id{d}, kind => 'calls',      provenance => 'static' });
$s->insert_edge({ source => $id{d},   target => $id{a}, kind => 'calls',      provenance => 'static' });  # d->a: a cycle

my $q = App::PerlGraph::Query->new(store => $s);
sub chain { join ',', map { $_->{name} } @_ }

is chain($q->path('P::a', 'P::c')), 'a,c',   'shortest path: direct a->c beats a->b->c';
is chain($q->path('P::a', 'P::d')), 'a,c,d', 'multi-hop path a->c->d';
is chain($q->path('P::b', 'P::d')), 'b,c,d', 'path from a mid-graph node';
is chain($q->path('P::a', 'P::a')), 'a',     'a symbol reaches itself (0 hops)';
is [ $q->path('P::a', 'P::x') ], [],         'no path -> empty list';
is [ $q->path('P', 'P::a') ],     [],        'contains edges are not call paths';
is chain($q->path('P::d', 'P::b')), 'd,a,b', 'traverses a cycle (d->a->b) without looping';

# the edge that reached each hop is tagged for display
my @p = $q->path('P::a', 'P::d');
is $p[1]{_via}, 'references', 'hop carries the edge kind that reached it (a->c is a reference)';

# --- Format ---
my $out = App::PerlGraph::Format::path('P::a', 'P::d', [ $q->path('P::a', 'P::d') ]);
like $out, qr/## Path: P::a -> P::d/,                    'format: header';
like $out, qr/`P::a`.*\n.*-> `P::c`.*\n.*-> `P::d`/s,    'format: arrowed chain in order';
like $out, qr/\(2 hops\)/,                               'format: hop count';
like App::PerlGraph::Format::path('P::a', 'P::x', []), qr/_no path found_/, 'format: no-path message';

# --- CLI over a real index (needs the grammar; core tests above do not) ---
my $have_grammar = eval { App::PerlGraph::Parser->new->parse_string("1;\n"); 1 };
if ($have_grammar) {
    my $dir = tempdir; $dir->child('lib')->mkpath;
    $dir->child('lib/P.pm')->spew_utf8("package P;\nsub run { help() }\nsub help { 1 }\n1;\n");
    { open my $fh, '>', \my $i; local *STDOUT = $fh; App::PerlGraph::CLI->run('index', "$dir") }
    my $rc;
    { open my $fh, '>', \my $cout; local *STDOUT = $fh;
      $rc = App::PerlGraph::CLI->run('path', 'P::run', 'P::help', "$dir");
      like $cout, qr/## Path: P::run -> P::help/, 'cli: header';
      like $cout, qr/-> `P::help`/,               'cli: path reaches the target'; }
    is $rc, 0, 'pcg path exits 0';
}
else { note 'skipping CLI path test: grammar not built' }

done_testing;
