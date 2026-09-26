"""Works out what to bake tomorrow from today's sales and what's left on the shelves."""

from dataclasses import dataclass
from datetime import date
import csv

SAFETY_MARGIN = 1.15  # bake 15% more than we expect to sell


@dataclass
class Product:
    name: str
    sold_today: int
    left_over: int
    batch_size: int = 12

    @property
    def expected_demand(self) -> float:
        # Leftovers mean we overbaked, so trust sales a little less.
        return self.sold_today * (0.9 if self.left_over > 5 else 1.0)

    def batches_needed(self) -> int:
        target = self.expected_demand * SAFETY_MARGIN - self.left_over
        return max(0, round(target / self.batch_size))


def load(path: str) -> list[Product]:
    with open(path, newline="") as f:
        return [
            Product(row["Item"], int(row["Quantity"]), int(row.get("Left", 0) or 0))
            for row in csv.DictReader(f)
        ]


def plan(products: list[Product]) -> dict[str, int]:
    return {p.name: p.batches_needed() for p in products if p.batches_needed() > 0}


if __name__ == "__main__":
    tomorrow = plan(load("Sales.csv"))
    print(f"Bake list for {date.today():%A %d %B}")
    for name, batches in sorted(tomorrow.items(), key=lambda item: -item[1]):
        print(f"  {name:<20} {batches:>2} batch{'es' if batches != 1 else ''}")
