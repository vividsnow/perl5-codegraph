use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
my $src = <<'PL';
package Acme::Widget;
use strict; use warnings;
use parent 'Acme::Base';
use Exporter 'import';
our @ISA = ('Other::Base');
our @EXPORT_OK = qw(make build PI);
use constant PI => 3.14159;
use constant { E => 2.718, _SECRET => 42 };
use constant DBG => $ENV{DBG_LEVEL};
use constant DEFAULTS => { inner_key => 7 };
sub make { 1 }
sub build { 2 }
PL
my $tree = eval { $parser->parse_string($src) } or skip_all "grammar not built: $@";
my $out  = App::PerlGraph::Extractor->new(file_path => 'lib/Acme/Widget.pm')->extract($tree);

my @extends = grep { $_->{kind} eq 'extends' } @{ $out->{edges} };
ok( (grep { (($_->{metadata}||{})->{name}//'') eq 'Acme::Base'  } @extends), 'extends Acme::Base (use parent)' );
ok( (grep { (($_->{metadata}||{})->{name}//'') eq 'Other::Base' } @extends), 'extends Other::Base (our @ISA)' );

my @imports = grep { $_->{kind} eq 'imports' } @{ $out->{edges} };
ok( (grep { (($_->{metadata}||{})->{module}//'') eq 'Exporter' } @imports), 'imports Exporter' );
ok( !(grep { (($_->{metadata}||{})->{module}//'') =~ /strict|warnings/ } @imports), 'pragmas not imported' );

ok( !(grep { (($_->{metadata}||{})->{module}//'') eq 'constant' } @imports), '`use constant` is not an import' );

my %by_q = map { $_->{qualified_name} => $_ } @{ $out->{nodes} };
is $by_q{'Acme::Widget'}{kind}, 'class', 'package with parent/ISA becomes class';
is $by_q{'Acme::Widget::make'}{is_exported},  1, 'make is exported';
is $by_q{'Acme::Widget::build'}{is_exported}, 1, 'build is exported';

# `use constant` (both forms) -> constant nodes
is $by_q{'Acme::Widget::PI'}{kind},      'constant', 'use constant FOO => ... -> constant node';
is $by_q{'Acme::Widget::PI'}{is_exported}, 1,        'an exported constant gets is_exported';
is $by_q{'Acme::Widget::E'}{kind},       'constant', 'use constant { A => ... } hash form -> constant node';
is $by_q{'Acme::Widget::_SECRET'}{kind}, 'constant', 'hash-form second constant node';
is $by_q{'Acme::Widget::_SECRET'}{visibility}, 'private', 'leading-underscore constant is private';
is $by_q{'Acme::Widget::DBG'}{kind}, 'constant',     'constant with an expression value is captured';
ok !exists $by_q{'Acme::Widget::DBG_LEVEL'},         'a hash-subscript key in the VALUE ($ENV{DBG_LEVEL}) is NOT a phantom constant';
is $by_q{'Acme::Widget::DEFAULTS'}{kind}, 'constant','constant whose value is a hashref is captured';
ok !exists $by_q{'Acme::Widget::inner_key'},         "a value hashref's key (DEFAULTS => { inner_key => ... }) is NOT a phantom constant";
done_testing;
