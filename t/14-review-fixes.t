use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::CLI;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# --- #1: FTS search must tolerate ':' and other FTS5 operator chars, not crash ---
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'n', kind => 'function', name => 'make',
    qualified_name => 'Acme::Widget::make', file_path => 'f' });
my @hit = eval { $s->search('Acme::Widget') };
ok !$@, 'search tolerates :: (no FTS5 crash)' or diag $@;
is scalar(@hit), 1, 'qualified-name search still finds the node';
ok( (eval { $s->search('a-b'); $s->search('c+d'); $s->search('x*'); 1 }),
    'search tolerates -, +, * without dying' );

# --- #3: a scalar `my $ISA = ...` must NOT be read as @ISA inheritance ---
my $t = $parser->parse_string("package Q;\nmy \$ISA = 'Bogus::Base';\nsub z { 1 }\n");
my $o = App::PerlGraph::Extractor->new(file_path => 'q.pm')->extract($t);
ok !(grep { $_->{kind} eq 'extends' } @{ $o->{edges} }), 'scalar $ISA is not inheritance';
my ($q) = grep { $_->{qualified_name} eq 'Q' } @{ $o->{nodes} };
is $q->{kind}, 'package', 'scalar $ISA does not promote package to class';

# real @ISA still works
my $t2 = $parser->parse_string("package R;\nour \@ISA = ('Real::Base');\n");
my $o2 = App::PerlGraph::Extractor->new(file_path => 'r.pm')->extract($t2);
ok( (grep { $_->{kind} eq 'extends' && (($_->{metadata}||{})->{name}//'') eq 'Real::Base' } @{ $o2->{edges} }),
    'our @ISA still produces extends' );

# --- #2: a command missing its required arg returns usage (2), not a raw croak ---
my $rc;
{ open my $e, '>', \my $err; local *STDERR = $e; $rc = App::PerlGraph::CLI->run('callers'); }
is $rc, 2, 'missing-arg command returns usage code, not a crash';
done_testing;
