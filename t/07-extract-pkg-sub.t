use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
my $src = "package Foo::Bar;\nsub greet { 1 }\nsub _hidden { 2 }\n";
my $tree = eval { $parser->parse_string($src) } or skip_all "grammar not built: $@";

my $out = App::PerlGraph::Extractor->new(file_path => 'lib/Foo/Bar.pm')->extract($tree);

my %by_q = map { $_->{qualified_name} => $_ } @{ $out->{nodes} };
ok $by_q{'Foo::Bar'},                       'package node emitted';
is $by_q{'Foo::Bar'}{kind}, 'package',      'package kind';
ok $by_q{'Foo::Bar::greet'},                'sub node emitted with qname';
is $by_q{'Foo::Bar::greet'}{kind}, 'function', 'function kind';
is $by_q{'Foo::Bar::_hidden'}{visibility}, 'private', 'leading underscore => private';

my @contains = grep { $_->{kind} eq 'contains' } @{ $out->{edges} };
ok( (grep { $_->{source} eq $by_q{'Foo::Bar'}{id} && $_->{target} eq $by_q{'Foo::Bar::greet'}{id} } @contains),
    'package contains sub' );

# block-form `package NAME { ... }` scopes to its block; following code is main.
{
    my $bt = $parser->parse_string("package Util { sub helper { 1 } }\nsub do_stuff { 1 }\n");
    my %q = map { ($_->{qualified_name} => 1) } @{ App::PerlGraph::Extractor->new(file_path => 'b.pm')->extract($bt)->{nodes} };
    ok  $q{'Util::helper'},    'block-form package: inner sub is Util::helper';
    ok  $q{'main::do_stuff'},  'block-form package: a following sub is main, not the block package';
    ok !$q{'Util::do_stuff'},  'block-form package does not leak its scope to siblings';
}

# two consecutive block-form packages each scope correctly.
{
    my $bt = $parser->parse_string("package A { sub a { 1 } }\npackage B { sub b { 1 } }\n");
    my %q = map { ($_->{qualified_name} => 1) } @{ App::PerlGraph::Extractor->new(file_path => 'c.pm')->extract($bt)->{nodes} };
    ok $q{'A::a'} && $q{'B::b'}, 'consecutive block-form packages scope independently';
    ok !$q{'A::b'} && !$q{'B::a'}, 'no cross-contamination between block packages';
}
done_testing;
