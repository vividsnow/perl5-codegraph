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
# M: a Moo class with a has-accessor, an is=>rwp private writer, a real method, and ONE broken call
$d->child('lib/M.pm')->spew_utf8(<<'PL');
package M;
use Moo;
has name  => (is => 'ro');
has level => (is => 'rwp');
sub greet { my $self = shift; $self->name }
sub run {
    my $self = shift;
    $self->greet;             # a real method            -> ok
    $self->name;              # a has-accessor           -> ok
    $self->_set_level(2);     # the is=>rwp private writer -> ok (needs the extractor fix)
    $self->missing_method;    # genuinely undefined       -> the one finding
}
1;
PL
# E: extends an EXTERNAL base -> MRO not closed -> never flagged
$d->child('lib/E.pm')->spew_utf8("package E;\nuse parent 'Exporter';\nsub go { my \$self = shift; \$self->whatever }\n1;\n");
# A: has AUTOLOAD -> dynamic dispatch escape hatch -> never flagged
$d->child('lib/A.pm')->spew_utf8("package A;\nsub AUTOLOAD { 1 }\nsub go { my \$self = shift; \$self->anything }\n1;\n");
# O: an opaque $obj receiver -> unknown class -> never flagged
$d->child('lib/O.pm')->spew_utf8("package O;\nsub go { my (\$self, \$obj) = \@_; \$obj->frob }\n1;\n");

my $s = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$d")->index_all;
my $f = App::PerlGraph::Query->new(store => $s)->checkcalls;

is scalar @$f, 1,                 'exactly one broken call found (the genuine one, no false positives)';
is $f->[0]{class},  'M',              'finding: the receiver class';
is $f->[0]{method}, 'missing_method', 'finding: the missing method';
is $f->[0]{caller}, 'M::run',         'finding: the caller';

my %flagged; $flagged{"$_->{class}->$_->{method}"} = 1 for @$f;
ok !$flagged{'M->name'},       'a Moo has-accessor is NOT flagged (accessors are captured)';
ok !$flagged{'M->_set_level'}, 'a Moo is=>rwp private writer (_set_<attr>) is NOT flagged';
ok !$flagged{'M->greet'},      'a real method is NOT flagged';
ok !(grep { $_->{class} eq 'E' } @$f), 'a class with an external (non-closed) MRO is NOT flagged';
ok !(grep { $_->{class} eq 'A' } @$f), 'a class with AUTOLOAD is NOT flagged';
ok !(grep { $_->{class} eq 'O' } @$f), 'an opaque $obj receiver (unknown class) is NOT flagged';

my $txt = App::PerlGraph::Format::checkcalls($f);
like $txt, qr/Broken method calls/,      'format: header';
like $txt, qr/->missing_method.*M::run/, 'format: the finding line';
like $txt, qr/heuristic/,                'format: the honest caveat';
like App::PerlGraph::Format::checkcalls([]), qr/_none found_/, 'format: clean-state message';

done_testing;
