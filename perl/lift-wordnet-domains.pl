#!/usr/bin/env perl -w

use common::sense;

use WordNet::QueryData;
use JSON::XS;
use List::Util qw(any);
use List::MoreUtils qw(uniq);

use File::Glob ':bsd_glob';
use File::Spec;
use String::Similarity;

## Updated to handle lifting to Wordnet 3.1

my $input = "/Users/stuart/git/CoarseWordNet/CoarseWordNet/resources/wn-domains-3.2/wn-domains-3.2-20070223";
my $wordnet = "/Users/stuart/git/CoarseWordNet/CoarseWordNet/resources/WordNet-2.0";
my $newwordnet = "/Users/stuart/Downloads/WordNet-3.0";

my $sense_20_to_21 = "/Users/stuart/git/CoarseWordNet/CoarseWordNet/resources/sensemap01/";
my $sense_21_to_30 = "/Users/stuart/git/CoarseWordNet/CoarseWordNet/resources/sensemap23/";

my $codes = {
	noun => 'n',
	verb => 'v',
	adv => 'r',
	adj => 'a'
};

sub load_sense_mappings {
	my ($directory) = @_;

	say STDERR "Loading sense mapping from $directory";

	my $path = File::Spec->rel2abs('*.{noun,verb,adv,adj}.*', $directory);

	my $result = {};

	my @list = bsd_glob($path);
	foreach my $file (@list) {
		my ($type) = ($file =~ m{\b(noun|verb|adv|adj)\b});
		my $code = $codes->{$type};
		say STDERR "Reading $file";
		open my $fh, "<", $file or die("Can't open: $file: $!");
		while (<$fh>) {
			chomp;
			s/:: /::;/g;
			my @fields = split(' ');
			my $score = 100;
			if ($fields[0] =~ m{^\d+$}) {
				$score = shift(@fields);
			}
			next unless ($score >= 90);
			my $from = shift(@fields);
			
			my (undef, $from_offset) = split(';', $from);
			my @to_offsets = ();

			foreach my $field (@fields) {
				my (undef, $to_offset) = split(';', $field);
				push @to_offsets, $to_offset;
			}

			$result->{"$from_offset-$code"} = [ map { "$_-$code" } @to_offsets ];
		}
		close($fh);
	}

	return $result;
}

my $map_20_to_21 = load_sense_mappings($sense_20_to_21);
my $map_21_to_30 = load_sense_mappings($sense_21_to_30);

my $wn = WordNet::QueryData->new( dir => "$wordnet/dict/", noload => 1);
my $newwn = WordNet::QueryData->new( dir => "$newwordnet/dict/", noload => 1);

# my $result = {};

sub write_record {
	my ($sense, $codes) = @_;

	my $offset = $newwn->offset($sense);
	my ($word, $type, $senseOffset) = split('#', $sense);

	say "$offset-$type $sense $codes";
}

open(my $fh, "<", $input) or die("Can't open $input: $!");
TERM: while (<$fh>) {
	chomp;
	my ($synset, $codes) = split(/\t/);
	next TERM if ($codes eq 'factotum');

	my ($offset, $type) = split('-', $synset);
	my @codes = split(/\s+/, $codes);

	my @senses = $wn->getAllSenses("$offset", $type);

	## Okay, if we find this good, otherwise complain and skip
	if (@senses == 0) {
		say STDERR "Invalid senses: $synset";
		next TERM;
	}

	## We have a single sense. Let's decompose it
	my $sense = $senses[0];
	my ($word, $type, $senseNumber) = split('#', $sense);

	## Now look for all the senses in the old database
	my @allSenses = $wn->querySense("${word}#${type}");
	my $oldSenseCount = @allSenses;

	if ($oldSenseCount == 0) {
		say STDERR "Failed to find any existing senses";
		next TERM;
	}

	## Now look for all the senses in the new database
	my @newAllSenses = $newwn->querySense("${word}#${type}");
	my $newSenseCount = @newAllSenses;

	if ($newSenseCount == 1 && $oldSenseCount == 1) {
		write_record($sense, $codes);
		next TERM;
	}

	## If there are no new senses, don't map, but warn
	if ($newSenseCount == 0) {
		say STDERR "No new mapping: $sense";
		next TERM;
	}

	## If there is only one new sense and multiple old senses, assume a merge
	if ($newSenseCount == 1 && $oldSenseCount > 1) {
		write_record($sense, $codes);
		next TERM;
	}


	## We might have multiple senses, so try mapping
	my $senses_21 = $map_20_to_21->{$synset};
	my $senses_30;
	if (@$senses_21 == 1) {
		$senses_30 = $map_21_to_30->{$senses_21->[0]};
		if (@$senses_30 == 1) {

			my ($offset, $type) = split('-', $senses_30->[0]);
			my @newsenses = $newwn->getAllSenses("$offset", $type);
			foreach my $newsense (@newsenses) {
				write_record($newsense, $codes);
			}
			next TERM;
		}
	}

	## Okay, we have to search for a corresponding new definition with the
	## same gloss as the old one.
	my ($gloss) = $wn->querySense($sense, 'glos');
	$gloss =~ s{; ".*}{};
	my $newgloss;
	say STDERR "Old gloss: $gloss";

	## Now check all the new definitions for something close
	my $best = undef;
	my $similarity = 0;
	foreach my $newsense (@newAllSenses) {
		($newgloss) = $newwn->querySense($newsense, 'glos');
		$newgloss =~ s{; ".*}{};
		if ($newgloss eq $gloss) {
			write_record($newsense, $codes);
			next TERM;
		}

		my $guess = similarity($gloss, $newgloss);
		if ($guess > $similarity) {
			$similarity = $guess;
			$best = $newsense;
		}
		say STDERR "New gloss: $newgloss";
	}

	if ($similarity > 0.1) {
		write_record($best, $codes);
		next TERM;
	}

	if (1) {
		say "Failed for ", @senses;
		$DB::single = 1;
		next TERM;
	}
	
}
close($fh);

1;