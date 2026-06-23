use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;

# Functions with fixed / defaulted / slurpy signatures, and calls with right + wrong arity.
$d->child('lib/P.pm')->spew_utf8(<<'PL');
package P;
use v5.36;
sub add  ($a, $b)     { $a + $b }
sub opt  ($a, $b = 5) { $a + $b }
sub vary ($a, @rest)  { $a }
sub noarg ()          { 42 }
sub run {
    my $ok    = add(1, 2);        # right -> no finding
    my $few   = add(1);           # too few  -> FINDING (expects 2, got 1)
    my $many  = add(1, 2, 3);     # too many -> FINDING (expects 2, got 3)
    my $od    = opt(1);           # right (b defaulted) -> no finding
    my $vok   = vary(1, 2, 3, 4); # slurpy -> variadic, not checked
    my $nz    = noarg();          # right (0 args) -> no finding
    my @list  = (1, 2);
    my $splat = add(@list);       # splat -> indeterminate -> skipped
}
1;
PL

# A traditional-OO method (a plain `sub` used via $self->) with a fixed signature.
$d->child('lib/Obj.pm')->spew_utf8(<<'PL');
package Obj;
use v5.36;
sub new   { bless {}, shift }
sub greet ($self, $name) { "hi $name" }
sub use_it {
    my $self = shift;
    $self->greet("x");   # right (invocant + 1 = 2) -> no finding
    $self->greet();      # too few -> FINDING (sig arity 2, got 1 incl. invocant)
}
1;
PL

my $s = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$d")->index_all;
my $q = App::PerlGraph::Query->new(store => $s);

my $f = $q->checkargs("$d");
is scalar @$f, 3, 'exactly the three wrong-arity calls are flagged (no false positives)';

my %by = map { ("$_->{callee}/$_->{got}" => $_) } @$f;
ok $by{'P::add/1'},    'add(1) flagged: too few';
ok $by{'P::add/3'},    'add(1, 2, 3) flagged: too many';
ok $by{'Obj::greet/1'},'$self->greet() flagged: a same-package method call counts its invocant';
is $by{'P::add/1'}{expected}, '2',     'a fixed signature reports an exact expected arity';

# none of the correct / defaulted / slurpy / splat calls produced a finding
ok !(grep { $_->{callee} eq 'P::opt' }  @$f), 'a defaulted param (opt(1)) is within arity -- not flagged';
ok !(grep { $_->{callee} eq 'P::vary' } @$f), 'a slurpy signature is variadic -- not checked';
ok !(grep { $_->{got} == 2 } @$f),            'add(1,2) and $self->greet("x") (the right calls) are not flagged';

# rendering
my $txt = App::PerlGraph::Format::checkargs($f);
like   $txt, qr/Wrong-arity calls/,        'renders a header';
like   $txt, qr/P::add.*expects 2.*got 1/, 'renders the callee, expected and got';
like   App::PerlGraph::Format::checkargs([]), qr/_none found_/, 'empty state renders cleanly';

done_testing;
