#!/usr/bin/env perl -w

use common::sense;

use Carp;
use WordNet::QueryData;
use JSON::XS;
use List::Util qw(any);
use List::MoreUtils qw(uniq firstidx);

use File::Glob ':bsd_glob';
use File::Spec;
use String::Similarity;
use Types::Serialiser;

## Updated to handle lifting to Wordnet 3.1

my $input = "/Users/stuart/git/CoarseWordNet/CoarseWordNet/resources/wn-domains-3.2/wn-affect-1.1";
my $wordnet = "/Users/stuart/Downloads/wordnet-1.6";
my $newwordnet = "/Users/stuart/Downloads/WordNet-3.0";

## XML is important here, too

use XML::LibXML;
my $wn = WordNet::QueryData->new( dir => "$wordnet/dict/", noload => 1);
my $newwn = WordNet::QueryData->new( dir => "$newwordnet/dict/", noload => 1);

my $parents = {};
my $children = {};

sub load_hierarchy {
	my $filename = File::Spec->rel2abs('a-hierarchy.xml', $input);
	my $doc = XML::LibXML->load_xml(location => $filename);
	my $root = $doc->documentElement();
	my @nodes = $root->findnodes("//categ");

	foreach my $node (@nodes) {
		my $name = $node->getAttribute('name');
		my $isa = $node->getAttribute('isa');
		next if (exists($parents->{$name}));
		$parents->{$name} = $isa if ($isa);
		push @{$children->{$isa}}, $name if ($isa);
	}

	return;
}

sub add_attribute {
	my ($attributes, $levels, $property, $pattern) = @_;
	my $index = firstidx { $_ =~ $pattern } @$levels;
	$attributes->{$property} = ($index == -1) ? Types::Serialiser::false : Types::Serialiser::true;
}


sub get_attributes {
	my ($category) = @_;
	my @levels = ();
	while(1) {
		push @levels, $category;
		$category = $parents->{$category};
		last if (! $category);
	}

	my $attributes = {};
	add_attribute($attributes, \@levels, 'emotion', qr/^emotion$/);
	add_attribute($attributes, \@levels, 'positive', qr/^positive-emotion$/);
	add_attribute($attributes, \@levels, 'negative', qr/^negative-emotion$/);
	add_attribute($attributes, \@levels, 'neutral', qr/^(?:neutral|ambiguous)-emotion$/);
	add_attribute($attributes, \@levels, 'anger', qr/^anger$/);
	add_attribute($attributes, \@levels, 'dislike', qr/^dislike$/);
	add_attribute($attributes, \@levels, 'joy', qr/^joy$/);
	add_attribute($attributes, \@levels, 'shame', qr/^shame$/);
	add_attribute($attributes, \@levels, 'regret', qr/^regret-sorrow$/);
	add_attribute($attributes, \@levels, 'surprise', qr/^surprise$/);
	add_attribute($attributes, \@levels, 'fear', qr/^negative-fear$/);
	add_attribute($attributes, \@levels, 'sadness', qr/^negative-fear$/);

	my $index = firstidx { $_ eq 'emotion' } @levels;
	$attributes->{category} = ($index == -1) ? 'none' : $levels[$index - 2];
	
	return $attributes;
}

sub map_synset {
	my ($id) = @_;

	my ($pos, $offset) = split('#', $id);
	my @oldSenses = $wn->getAllSenses("$offset", $pos);

	## Okay, if we find this good, otherwise complain and skip
	if (@oldSenses == 0) {
		say STDERR "Invalid senses: $id";
		return;
	}

	my $sense = $oldSenses[0];
	my ($word, $type, $senseNumber) = split('#', $sense);

	## Now look for all the senses in the old database
	my @oldAllSenses = $wn->querySense("${word}#${type}");
	my $oldSenseCount = @oldAllSenses;

	if ($oldSenseCount == 0) {
		say STDERR "Failed to find any existing senses";
		return;
	}

	## Now look for all the senses in the new database
	my @newAllSenses = $newwn->querySense("${word}#${type}");
	my $newSenseCount = @newAllSenses;

	if ($newSenseCount == 1 && $oldSenseCount == 1) {
		return $newAllSenses[0];
	}

	## If there are no new senses, don't map, but warn
	if ($newSenseCount == 0) {
		say STDERR "No new mapping: $sense";
		return;
	}

	## If there is only one new sense and multiple old senses, assume a merge
	if ($newSenseCount == 1 && $oldSenseCount > 1) {
		return $newAllSenses[0]
	}

	## OK, we need to resolve. And guess what, this time without synset mapping files
	my ($gloss) = $wn->querySense($sense, 'glos');
	$gloss =~ s{; ".*}{};
	my $newgloss;
	# say STDERR "Old gloss: $gloss";

	## Now check all the new definitions for something close
	my $best = undef;
	my $similarity = 0;
	foreach my $newSense (@newAllSenses) {
		($newgloss) = $newwn->querySense($newSense, 'glos');
		$newgloss =~ s{; ".*}{};
		# say STDERR "New gloss: $newgloss";
		if ($newgloss eq $gloss) {
			return $newSense;
		}

		my $guess = similarity($gloss, $newgloss);
		if ($guess > $similarity) {
			$similarity = $guess;
			$best = $newSense;
		}
	}

	if ($similarity > 0.1) {
		return $best;
	}

	carp("Failed to map $id");
	return;
}

my $result = {};

sub load_synsets {
	my $filename = File::Spec->rel2abs('a-synsets.xml', $input);
	my $doc = XML::LibXML->load_xml(location => $filename);
	my $root = $doc->documentElement();

	my $mapping = {};

	foreach my $node ($root->findnodes("//noun-syn")) {
		my $id = $node->getAttribute('id');
		my $categ = $node->getAttribute('categ');

		my $mappedSynset = map_synset($id);

		$mapping->{$id} = $mappedSynset;
		my $attributes = get_attributes($categ);
		$result->{$mappedSynset} = $attributes;

		my @hypoSynsets = $newwn->querySense($mappedSynset, 'hypo');
		foreach my $hypo (@hypoSynsets) {
			next if (exists($result->{$hypo}));
			my %copy = %{$result->{$mappedSynset}};
			$result->{$hypo} = \%copy;
		}

		next;
	}

	foreach my $node ($root->findnodes("//adj-syn"), $root->findnodes("//adv-syn"), $root->findnodes("//verb-syn")) {
		my $id = $node->getAttribute('id');
		my $nounId = $node->getAttribute('noun-id');
		my $causStat = $node->getAttribute('caus-stat');

		my $mappedSynset = map_synset($id);
		next if (! defined($mappedSynset));

		my $nounSynset = $mapping->{$nounId};
		croak if (! $nounSynset);

		my %copy = %{$result->{$nounSynset}};
		$result->{$mappedSynset} = \%copy;
		$result->{$mappedSynset}->{role} = ($causStat eq 'caus') ? 'causative' : 'stative';
		$result->{$mappedSynset}->{derived} = $nounSynset;

		my @hypoSynsets = $newwn->querySense($mappedSynset, 'hypo');
		foreach my $hypo (@hypoSynsets) {
			next if ($hypo eq $nounSynset);
			next if (exists($result->{$hypo}));
			my %copy = %{$result->{$mappedSynset}};
			$result->{$hypo} = \%copy;
			$result->{$hypo}->{original} = $mappedSynset;
		}

		next;
	}
}


load_hierarchy();
load_synsets();

foreach my $key (keys %$result) {
	my $offset = $newwn->offset($key);
	my ($word, $pos, $senseOffset) = split('#', $key);
	$result->{$key}->{offset} = "${offset}-${pos}";
}

my $coder = JSON::XS->new->ascii->pretty->canonical(1);
my $string = $coder->encode($result);
$string =~ s{\[\n\s+}{\[ }g;
$string =~ s{\n\s+\]}{ \]}g;
say $string;

1;