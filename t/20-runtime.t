use v5.36;
use Test2::V0;
use App::PerlGraph::Runtime;
use Path::Tiny qw(path tempfile);

my $lib = path('t/corpus/oo/lib')->absolute->stringify;
my $res = App::PerlGraph::Runtime->new(lib_dirs => [$lib])
    ->introspect([ "$lib/Animal.pm", "$lib/Dog.pm" ], ['Animal', 'Dog']);
ok $res, 'introspect returned a result' or skip_all "runtime introspection unavailable: @{[%ENV]}";

my %node = map { $_->{qualified_name} => $_ } @{ $res->{nodes} };
is $node{'Animal::speak'}{provenance}, 'symtab', 'symtab node for Animal::speak';
ok $node{'Dog::sound'},                          'Dog own sub present (symtab)';

my @edge = @{ $res->{edges} };
ok( (grep { $_->{kind} eq 'extends' && $_->{source_qname} eq 'Dog'
            && $_->{target_qname} eq 'Animal' && $_->{provenance} eq 'symtab' } @edge),
    'real @ISA -> extends Dog -> Animal (symtab)' );
ok( (grep { $_->{kind} eq 'calls' && $_->{source_qname} eq 'Animal::speak'
            && $_->{target_qname} eq 'Animal::sound' && $_->{provenance} eq 'optree' } @edge),
    'optree resolves dynamic $self->sound in Animal::speak -> Animal::sound' );
ok( (grep { $_->{source_qname} eq 'Dog::fetch' && $_->{target_qname} eq 'Animal::sound' } @edge),
    'optree resolves Animal::sound() call in Dog::fetch' );

# fail-soft: a module that dies on load must not crash introspect
my $bad = tempfile(SUFFIX => '.pm');
$bad->spew_utf8("package Boom;\ndie 'boom at load time';\n1;\n");
my $res2 = App::PerlGraph::Runtime->new(lib_dirs => [$bad->parent->stringify], timeout => 5)
    ->introspect(["$bad"], ['Boom']);
ok defined $res2, 'fail-soft: a dying module does not crash introspect';

# MOP (Moose) -- skip if Moose unavailable
SKIP: {
    skip "Moose not installed", 1 unless eval { require Moose; 1 };
    my $m = App::PerlGraph::Runtime->new(lib_dirs => [$lib])
        ->introspect([ "$lib/Role/Printable.pm", "$lib/Widget.pm" ], ['Widget']);
    my $role  = grep { $_->{kind} eq 'implements' && $_->{target_qname} eq 'Role::Printable'
                       && $_->{provenance} eq 'mop' } @{ $m->{edges} };
    my $field = grep { $_->{kind} eq 'field' && $_->{qualified_name} eq 'Widget::size'
                       && $_->{provenance} eq 'mop' } @{ $m->{nodes} };
    ok $role && $field, 'MOP: Moose role (implements) + attribute (field) introspected';
}
# over-attribution guard: a method call on a non-$self receiver must NOT resolve
# against the enclosing package (review finding); $self-> calls still resolve.
{
    my $r3 = App::PerlGraph::Runtime->new(lib_dirs => [$lib])
        ->introspect([ "$lib/Animal.pm", "$lib/Caller.pm" ], ['Animal', 'Caller']);
    my @e = @{ $r3->{edges} };
    ok !(grep { $_->{source_qname} eq 'Caller::run' && $_->{target_qname} eq 'Caller::name' } @e),
        '$other->name is NOT mis-resolved to the enclosing Caller::name';
    ok( (grep { $_->{source_qname} eq 'Caller::greet' && $_->{target_qname} eq 'Caller::name' } @e),
        '$self->name still resolves within the package' );
}
done_testing;
