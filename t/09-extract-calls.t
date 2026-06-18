use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
my $src = <<'PL';
package P;
sub a { helper(); P::Other::log("x"); Thing->build }
sub helper { 1 }
PL
my $tree = eval { $parser->parse_string($src) } or skip_all "grammar not built: $@";
my $out  = App::PerlGraph::Extractor->new(file_path => 'lib/P.pm')->extract($tree);

my %ref = map { $_->{reference_name} => $_ } @{ $out->{refs} };
ok $ref{helper},                     'plain call captured';
is $ref{helper}{reference_kind}, 'call', 'call kind';
ok $ref{'P::Other::log'},            'qualified call captured';
ok $ref{build},                      'method call captured';
is $ref{build}{reference_kind}, 'method_call', 'method_call kind';
is $ref{build}{candidates}{receiver}, 'Thing', 'receiver hint recorded';

my ($a) = grep { $_->{qualified_name} eq 'P::a' } @{ $out->{nodes} };
is $ref{helper}{from_node_id}, $a->{id}, 'call attributed to enclosing sub';
done_testing;
