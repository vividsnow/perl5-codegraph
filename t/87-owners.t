use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
# fileA::a is depended on from fileB (two cross-file inbound edges); fileB depends on nothing
$s->insert_node({ id => 'a', kind => 'function', name => 'a', qualified_name => 'A::a', file_path => 'fileA', start_line => 1 });
$s->insert_node({ id => 'b', kind => 'function', name => 'b', qualified_name => 'B::b', file_path => 'fileB', start_line => 1 });
$s->insert_node({ id => 'c', kind => 'function', name => 'c', qualified_name => 'B::c', file_path => 'fileB', start_line => 2 });
$s->insert_edge({ source => 'b', target => 'a', kind => 'calls', provenance => 'static' });
$s->insert_edge({ source => 'c', target => 'a', kind => 'calls', provenance => 'static' });
$s->insert_edge({ source => 'c', target => 'b', kind => 'calls', provenance => 'static' });   # same-file: not counted

# fileA: one author (100%); fileB: two authors, majority committer 'other'
my $authors = { fileA => { solo => 10 }, fileB => { solo => 3, other => 5 } };
my $q = App::PerlGraph::Query->new(store => $s);
my $rows = $q->owners($authors);
my %by = map { ($_->{file} => $_) } @$rows;

is $by{fileA}{owner}, 'solo',  'fileA primary owner';
is $by{fileA}{fanin}, 2,       'fileA has 2 cross-file inbound deps (same-file edge not counted)';
ok $by{fileA}{share} == 1,     'fileA is single-owned (100%)';
is $by{fileB}{owner}, 'other', 'fileB owner is the majority committer';
ok abs($by{fileB}{share} - 5/8) < 1e-9, 'fileB share is the top author fraction';
is $by{fileB}{fanin}, 0,       'fileB has no cross-file inbound deps';
is $rows->[0]{file}, 'fileA',  'ranked by inbound deps -- most-depended-upon first';

my $txt = App::PerlGraph::Format::owners($rows);
like   $txt, qr/`fileA`.*bus-factor risk/, 'format: a single-owned, depended-upon file is flagged';
unlike $txt, qr/`fileB`.*bus-factor risk/, 'format: a multi-author file is not flagged';
like   App::PerlGraph::Format::owners([]), qr/no git history/, 'format: no-history message';

done_testing;
