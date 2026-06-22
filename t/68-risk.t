use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Git;
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

# --- App::PerlGraph::Git: churn + transactions against a controlled repo --------
SKIP: {
    skip "git unavailable", 11 unless eval { my $v = `git --version 2>/dev/null`; $? == 0 && $v =~ /git/ };
    my $g = tempdir;
    my @gitc = ('git', '-C', "$g");
    system @$_ for [@gitc, 'init', '-q'], [@gitc, 'config', 'user.email', 't@t'], [@gitc, 'config', 'user.name', 't'];
    my $commit = sub (@files) {
        $g->child($_)->parent->mkpath, $g->child($_)->append("x\n") for @files;
        system @gitc, 'add', '-A';
        system @gitc, 'commit', '-qm', "touch @files";
    };
    $commit->('lib/A.pm', 'lib/B.pm');   # commit 1
    $commit->('lib/A.pm');               # commit 2
    $commit->('lib/A.pm', 'lib/C.pm');   # commit 3

    my $git = App::PerlGraph::Git->new(root => "$g");
    ok $git->available, 'available() is true inside a git work tree';
    my $churn = $git->churn;
    is $churn->{'lib/A.pm'}, 3, 'A.pm churned in 3 commits';
    is $churn->{'lib/B.pm'}, 1, 'B.pm churned once';
    is scalar @{ $git->commits }, 3, 'three commit transactions parsed';

    # churn(since => REF) counts only commits in REF..HEAD (e.g. risk on the current branch)
    my $recent = $git->churn(since => 'HEAD~1');                # only commit 3 (lib/A.pm, lib/C.pm)
    is $recent->{'lib/A.pm'}, 1, 'churn(since => HEAD~1) counts only commits after the ref';
    ok !exists $recent->{'lib/B.pm'}, '... excluding a file touched only in older commits';
    is $git->churn(since => 'HEAD'), {}, 'churn(since => HEAD) is empty (no commits in the range)';

    # security: a leading-dash "ref" is git option-injection (--output=FILE -> arbitrary
    # file write), never a valid ref -- it is rejected and never reaches git.
    my $evil = "$g/PWNED";
    is $git->changed("--output=$evil"), [],      'changed() rejects a leading-dash ref (option injection)';
    is $git->show("--output=$evil", 'x'), undef, 'show() rejects a leading-dash ref';
    ok !-e $evil,                                 'the --output= injection wrote no file';

    my $ng = tempdir;
    ok !App::PerlGraph::Git->new(root => "$ng")->available, 'available() is false outside a repo';
}

# --- Query::risk: churn x fan-in --------------------------------------------------
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
# hot(): 3 callers, in a file churned 10x  -> highest risk
# cold(): 3 callers, in a file churned 1x  -> low risk
$s->insert_node({ id => $_, kind => 'function', name => $_, qualified_name => "P::$_",
    file_path => ($_ eq 'hot' ? 'lib/Hot.pm' : 'lib/Cold.pm'), start_line => 1 }) for qw(hot cold a b c);
$s->insert_edge({ source => $_, target => 'hot',  kind => 'calls', provenance => 'static' }) for qw(a b c);
$s->insert_edge({ source => $_, target => 'cold', kind => 'calls', provenance => 'static' }) for qw(a b c);

my $q = App::PerlGraph::Query->new(store => $s);
my @risk = $q->risk({ 'lib/Hot.pm' => 10, 'lib/Cold.pm' => 1 }, limit => 5);
is $risk[0]{node}{qualified_name}, 'P::hot', 'highest risk = churn x fan-in (hot)';
is $risk[0]{score},               30,       '10 churn x 3 callers = 30';
ok +(grep { $_->{node}{qualified_name} eq 'P::cold' } @risk), 'a low-churn depended-upon sub still appears';
ok !(grep { ($_->{node}{file_path} // '') !~ /Hot|Cold/ } @risk), 'only churned files contribute';

# a depended-upon-but-unchurned symbol is not risk (no churn entry for its file)
my @none = $q->risk({}, limit => 5);
is scalar @none, 0, 'no churn data -> no risk rows';

# format
my $txt = App::PerlGraph::Format::risk(\@risk);
like $txt, qr/Risk/i,                         'format: risk header';
like $txt, qr/`P::hot`.*churned 10.*3 caller/, 'format: shows churn x fan-in';
like App::PerlGraph::Format::risk([]), qr/_none_/, 'format: empty';

done_testing;
