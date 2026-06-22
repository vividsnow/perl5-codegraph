use v5.36;
use Test2::V0;
use App::PerlGraph::Model qw(is_builtin);
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

# core builtins that real code uses constantly -- they must be recognized so they
# don't masquerade as unresolved project calls.
ok is_builtin($_), "$_ is a recognized builtin"
    for qw(pack unpack glob fork waitpid wait exec system kill exit unlink mkdir
           rename stat lstat opendir readdir closedir binmode seek sysread sin cos
           hex oct quotemeta caller localtime send recv socket bind connect);
ok !is_builtin('frobnicate'), 'a non-builtin is not falsely recognized';

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# A bareword builtin call is consumed (not left unresolved); the SAME name used as
# a method call ($obj->pack) is NOT a builtin -- it must stay an unresolved method.
my $src = <<'PL';
package P;
sub run {
    my $self = shift;
    my @x = unpack('A4', $d);   # bareword builtin -> consumed
    fork();                     # bareword builtin -> consumed
    $obj->pack(1);              # method named like a builtin -> NOT consumed
    $obj->keys;                 # ditto
    frobnicate();               # unknown bareword -> stays unresolved
}
PL

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $out = App::PerlGraph::Extractor->new(file_path => 'P.pm')->extract($parser->parse_string($src));
$store->insert_node($_)       for @{ $out->{nodes} };
$store->insert_edge($_)       for @{ $out->{edges} };
$store->insert_unresolved($_) for @{ $out->{refs} };
App::PerlGraph::Resolver->new(store => $store)->resolve_all;

my %left = map { $_ => 1 } $store->unresolved_ref_names;
ok !$left{unpack}, 'bareword builtin unpack() consumed (not unresolved)';
ok !$left{fork},   'bareword builtin fork() consumed';
ok $left{pack},    'method $obj->pack stays unresolved (not consumed as a builtin)';
ok $left{keys},    'method $obj->keys stays unresolved (keys is a builtin only as a bareword)';
ok $left{frobnicate}, 'an unknown bareword call stays unresolved';

done_testing;
