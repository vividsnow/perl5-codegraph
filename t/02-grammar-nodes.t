use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Grammar qw(:all);

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
my $src = <<'PL';
package Acme::Widget;
use parent 'Acme::Base';
our @EXPORT_OK = qw(make);
sub make { 1 }
sub run { make(); Thing->build }
PL
my $tree = eval { $parser->raw_parse($src) } or skip_all "grammar not built: $@";

my %seen;
my @stack = ($tree->root_node);
while (my $n = shift @stack) {
    $seen{$n->type}++ if $n->is_named;
    push @stack, $n->child_nodes;
}
ok $seen{ NODE_PACKAGE() },     'package_statement present';
ok $seen{ NODE_SUB() },         'subroutine_declaration_statement present';
ok $seen{ NODE_USE() },         'use_statement present';
ok $seen{ NODE_CALL() },        'function_call_expression present';
ok $seen{ NODE_METHOD_CALL() }, 'method_call_expression present';
done_testing;
