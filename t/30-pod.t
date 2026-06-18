use v5.36;
use Test2::V0;
use App::PerlGraph::Pod;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Format;
use App::PerlGraph::Store;

my $pod = App::PerlGraph::Pod::extract(<<'POD');
package Foo;

=head2 greet

Say hello to someone.

=head2 C<< add($x, $y) >>

Adds two numbers and
returns the sum.

=cut

sub greet { }

=item run

Runs the thing.

=cut
POD

is   $pod->{greet}, 'Say hello to someone.',   'head2 greet -> doc';
like $pod->{add},   qr/Adds two numbers/,      'C<< add($x,$y) >> -> matched to add';
like $pod->{add},   qr/returns the sum/,       'multi-line doc captured';
is   $pod->{run},   'Runs the thing.',         '=item run -> doc';
ok   !exists $pod->{Foo},                      'a non-POD code line (package Foo;) creates no doc entry';

# e2e: docstrings attach to sub nodes, show in the node view, and are searchable
SKIP: {
    my $parser = eval { App::PerlGraph::Parser->new };
    skip "parser unavailable", 3 unless $parser && eval { $parser->parse_string("1;\n") };
    my $src = "package M;\n\n=head2 greet\n\nSays hi to a name.\n\n=cut\n\nsub greet { 1 }\n";
    my $out = App::PerlGraph::Extractor->new(file_path => 'M.pm', source => $src)
        ->extract($parser->parse_string($src));
    my ($g) = grep { $_->{qualified_name} eq 'M::greet' } @{ $out->{nodes} };
    is $g->{docstring}, 'Says hi to a name.', 'docstring attached to the sub node';
    like App::PerlGraph::Format::node_view('M::greet', [{ node => $g, callers => [], callees => [] }]),
        qr/Says hi to a name/, 'node view shows the docstring';
    my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
    $s->insert_node($_) for @{ $out->{nodes} };
    ok( (grep { $_->{qualified_name} eq 'M::greet' } $s->search('Says')), 'docstring is searchable via FTS' );
}
done_testing;
