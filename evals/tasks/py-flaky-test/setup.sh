#!/bin/bash
set -e
cat > shuffle.py <<'EOF'
import random

def deal(deck, hands):
    """Shuffle the deck and deal it round-robin into `hands` hands."""
    cards = list(deck)
    random.shuffle(cards)
    return [cards[i::hands] for i in range(hands)]
EOF
cat > test_shuffle.py <<'EOF'
import unittest
from shuffle import deal

class T(unittest.TestCase):
    def test_first_hand(self):
        hands = deal(range(8), 2)
        self.assertEqual(hands[0], [0, 2, 4, 6])

if __name__ == "__main__":
    unittest.main()
EOF
