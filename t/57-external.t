use v5.36;
use Test2::V0;
use App::PerlGraph::Model qw(is_external);
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

# --- unit: well-known CPAN exports + qualified external prefixes -------------
ok is_external($_), "$_ recognized as external"
    for qw(ok is isnt like is_deeply plan done_testing subtest diag pass fail
           use_ok cmp_ok exception croak confess carp first sum max reduce any
           blessed reftype weaken looks_like_number encode_json decode_json);
ok is_external($_), "$_ (qualified external) recognized"
    for qw(AE::timer EV::run POSIX::_exit Carp::croak IO::Socket::SSL::SSL_VERIFY_NONE
           Ref::Util::is_arrayref Test2::Tools::Compare::hash);
# the modern Test2 stack + Ref::Util + POSIX/Time::HiRes/Encode bareword exports
ok is_external($_), "$_ (modern CPAN export) recognized as external"
    for qw(D U hash array item field in_set match validator object meta number string bool
           is_plain_arrayref is_plain_hashref is_arrayref is_coderef
           strftime floor ceil tv_interval gettimeofday encode_utf8 decode_utf8 mock);
ok !is_external('my_handler'), 'a project-looking name is not external';
ok !is_external('My::App::run'), 'a project-qualified name is not external';

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

sub names_left ($src, $file) {
    my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
    my $out = App::PerlGraph::Extractor->new(file_path => $file)->extract($parser->parse_string($src));
    $store->insert_node($_)       for @{ $out->{nodes} };
    $store->insert_edge($_)       for @{ $out->{edges} };
    $store->insert_unresolved($_) for @{ $out->{refs} };
    App::PerlGraph::Resolver->new(store => $store)->resolve_all;
    return { map { $_ => 1 } $store->unresolved_ref_names };
}

# --- known-external bareword/qualified calls are consumed, unknowns are not --
my $left = names_left(<<'PL', 'P.pm');
package P;
use Test::More;
sub run {
    ok(1);
    is(2, 2);
    croak("boom");
    AE::timer(0, 0, sub { 1 });
    my_unknown_helper();
}
PL
ok !$left->{ok},     'Test::More ok() consumed (not a project gap)';
ok !$left->{is},     'is() consumed';
ok !$left->{croak},  'croak() consumed';
ok !$left->{'AE::timer'}, 'qualified AE::timer consumed';
ok $left->{my_unknown_helper}, 'a genuinely unknown bareword stays unresolved';

# --- guard: a project sub that shares an external name is NOT consumed -------
my $left2 = names_left(<<'PL', 'Q.pm');
package A; sub first { 1 }
package B; sub first { 2 }
package C; sub run { first() }
PL
ok $left2->{first}, 'an ambiguous project-defined `first` stays unresolved (not mistaken for List::Util)';

# resolution runs BEFORE the external-consume, so a project that DEFINES a
# qualified name matching an external prefix links to its own definition.
{
    my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
    my $out = App::PerlGraph::Extractor->new(file_path => 'C.pm')->extract($parser->parse_string(
        "package Carp;\nsub croak { 1 }\npackage Main;\nsub run { Carp::croak('x') }\n"));
    $store->insert_node($_) for @{$out->{nodes}}; $store->insert_edge($_) for @{$out->{edges}};
    $store->insert_unresolved($_) for @{$out->{refs}};
    App::PerlGraph::Resolver->new(store => $store)->resolve_all;
    my ($run) = $store->nodes_by_qname('Main::run');
    my @callees = map { $store->node($_->{target})->{qualified_name} }
                  grep { $_->{target} } $store->outgoing_edges($run->{id}, 'calls');
    ok scalar(grep { $_ eq 'Carp::croak' } @callees),
       'a project-defined Carp::croak resolves to itself, not consumed as external';
}

# the modern Test2/Ref::Util/POSIX bareword exports are consumed (not phantom-unresolved),
# while a genuine unknown call is still left for the resolver frontier.
my $t2 = names_left(<<'PL', 'T.pm');
package T;
use Test2::V0;
use Ref::Util qw(is_plain_arrayref);
use POSIX qw(strftime);
sub run {
    ok(D());
    my $h = hash { field a => 1; end };
    my $ok = is_plain_arrayref([]);
    my $when = strftime("%F", 0,0,0,1,0,100);
    return frobnicate();
}
PL
ok !$t2->{D} && !$t2->{hash} && !$t2->{field} && !$t2->{end}, 'Test2::Tools::Compare builders consumed as external';
ok !$t2->{is_plain_arrayref}, 'Ref::Util predicate consumed';
ok !$t2->{strftime},          'POSIX strftime bareword consumed';
ok  $t2->{frobnicate},        'a genuine unknown call still stays unresolved (no over-consumption)';

done_testing;
