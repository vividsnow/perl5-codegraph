use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $src = <<'PL';
package P;
sub simple { 42 }
sub branchy {
    my $x = shift;
    if    ($x > 0) { return 1 }
    elsif ($x < 0) { return -1 }
    for my $i (1 .. $x) { $x += $i if $i % 2 }
    return $x && 1 || 0;
}
PL
my $out = App::PerlGraph::Extractor->new(file_path => 'P.pm')->extract($parser->parse_string($src));
my %byq = map { ($_->{qualified_name} => $_) } @{ $out->{nodes} };

ok !($byq{'P::simple'}{metadata} && $byq{'P::simple'}{metadata}{complexity}),
   'a straight-line sub stores no complexity (cyclomatic 1 is the trivial default)';
ok +($byq{'P::branchy'}{metadata}{complexity} // 0) >= 5,
   'a branchy sub gets an elevated cyclomatic complexity (if/elsif/for/postfix-if/&&/||)';

# node view surfaces complexity in the header
my $view = { node => { qualified_name => 'P::branchy', kind => 'function', file_path => 'P.pm',
                       start_line => 3, metadata => { complexity => 7 } }, callers => [], callees => [] };
like App::PerlGraph::Format::node_view('P::branchy', [$view]), qr/complexity 7/, 'node view shows complexity';

# a trivial node's view does NOT add a complexity note
my $triv = { node => { qualified_name => 'P::simple', kind => 'function', file_path => 'P.pm', start_line => 2 },
             callers => [], callees => [] };
unlike App::PerlGraph::Format::node_view('P::simple', [$triv]), qr/complexity/, 'no complexity note for a trivial sub';

# hotspots annotates a hot, complex symbol with its complexity
my $h = { fan_in => [ { node => { qualified_name => 'P::branchy', kind => 'function', file_path => 'P.pm',
                                  start_line => 3, metadata => { complexity => 12 } }, count => 9, impact => 9 } ],
          fan_out => [], packages => [] };
like App::PerlGraph::Format::hotspots($h), qr/9 callers.*cx 12/, 'hotspots flags a hot + complex symbol';

done_testing;
