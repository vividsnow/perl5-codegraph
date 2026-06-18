use v5.36;
use Test2::V0;
use App::PerlGraph::XS;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Parser;

# unit: scan an .xs source
my $out = App::PerlGraph::XS->scan('Calc.xs', <<'XS');
#include "perl.h"
MODULE = Acme::Calc    PACKAGE = Acme::Calc

int
add(a, b)
    int a
  CODE:
    RETVAL = a + b;
  OUTPUT:
    RETVAL
XS
my ($add) = grep { $_->{qualified_name} eq 'Acme::Calc::add' } @{ $out->{nodes} };
ok $add,                              'XSUB add scanned';
is $add->{language}, 'xs',            'language = xs';
is $add->{metadata}{provenance}, 'xs','provenance = xs';
ok( (grep { $_->{kind} eq 'contains' && $_->{provenance} eq 'xs' } @{ $out->{edges} }),
    'package contains XSUB' );

# e2e: a Perl call into an XSUB resolves to the xs node (the Perl <-> C bridge)
my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built";
my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => 't/corpus/xs')->index_all;

my ($addn) = grep { $_->{language} eq 'xs' } $store->nodes_by_qname('Acme::Calc::add');
ok $addn, 'xs node indexed from the .xs file';
my ($compute) = $store->nodes_by_qname('Acme::Calc::compute');
my %tgt = map { $_->{target} => 1 } $store->outgoing_edges($compute->{id}, 'calls');
ok $tgt{ $addn->{id} }, 'Perl compute() -> XS add() call resolved (Perl<->C bridge)';

# section labels / post-label column-0 statements must NOT be mistaken for XSUBs
my $g = App::PerlGraph::XS->scan('X.xs', <<'XS');
MODULE = T    PACKAGE = T

void
go()
PPCODE:
helper_call(x);
XS
my @fns = grep { $_->{kind} eq 'function' } @{ $g->{nodes} };
is scalar(@fns), 1,      'only the real XSUB detected, not the post-label call';
is $fns[0]{name}, 'go',  'XSUB is go';
done_testing;
