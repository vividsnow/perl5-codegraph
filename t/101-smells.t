use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;

# Data: a small "god class" -- five methods, called from two other packages.
$d->child('lib/Data.pm')->spew_utf8(<<'PL');
package Data;
sub new { bless {}, shift }
sub a { 1 }
sub b { 2 }
sub c { 3 }
sub d { 4 }
1;
PL

# Worker: `process` is FEATURE-ENVIOUS of Data (calls four Data methods, none of Worker's own).
# `configure` has a LONG PARAMETER LIST (four params after the $self invocant).
$d->child('lib/Worker.pm')->spew_utf8(<<'PL');
package Worker;
use v5.36;
sub new { bless {}, shift }
sub process {
    Data::a();
    Data::b();
    Data::c();
    Data::d();
    return 1;
}
sub helper { 1 }
sub configure ($self, $host, $port, $user, $pass) { 1 }
1;
PL

# Other: a second external caller of Data (gives Data a fan-in of two distinct callers), but
# only calls TWO Data methods -- below the feature-envy threshold, so it must NOT be flagged.
$d->child('lib/Other.pm')->spew_utf8(<<'PL');
package Other;
sub run { Data::a(); Data::b(); return 1 }
1;
PL

my $s = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$d")->index_all;
my $q = App::PerlGraph::Query->new(store => $s);

# thresholds dialled down to the fixture's scale (defaults are 4 / 20 / 15 / 5)
my $r = $q->smells(fe_min => 4, gc_methods => 5, gc_fanin => 2, lp_min => 4);

# --- feature envy ---
my %envy = map { ($_->{node}{qualified_name} => $_) } @{ $r->{feature_envy} };
ok $envy{'Worker::process'},            'a method calling 4 foreign methods and none of its own is envious';
is $envy{'Worker::process'}{envied}, 'Data', 'feature envy names the envied class';
is $envy{'Worker::process'}{foreign}, 4,      'feature envy counts the distinct foreign calls';
ok !$envy{'Other::run'},                'a method below the foreign-call threshold is not flagged';

# --- god class ---
my %god = map { ($_->{class} => $_) } @{ $r->{god_class} };
ok $god{'Data'},            'a many-method, widely-called class is a god class';
is $god{'Data'}{methods}, 5, 'god class reports its method count';
is $god{'Data'}{fanin}, 2,   'god class reports its distinct external caller count';
ok !$god{'Worker'},         'a class with few external callers is not a god class';

# --- long parameter list ---
my %long = map { ($_->{node}{qualified_name} => $_) } @{ $r->{long_params} };
ok $long{'Worker::configure'},   'a sub with many params is flagged';
is $long{'Worker::configure'}{count}, 4, 'the $self invocant is not counted as a parameter';
ok !$long{'Data::a'},            'a no-arg sub is not flagged';

# --- renderer ---
my $txt = App::PerlGraph::Format::smells($r);
like $txt, qr/Refactoring smells/,        'format: header';
like $txt, qr/God class.*`Data`/s,        'format: god-class section';
like $txt, qr/Feature envy.*Worker::process/s, 'format: feature-envy section';
like $txt, qr/Long parameter list.*configure/s, 'format: long-param section';
like App::PerlGraph::Format::smells({ feature_envy => [], god_class => [], long_params => [] }),
    qr/_none found_/, 'format: clean-state message';

done_testing;
