import math
import re
import unittest
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PAGE = ROOT / "Fixtures" / "ForgeRuntime" / "V14" / "vector-drift" / "index.html"


def extract_object(source: str, marker: str, fields: tuple[str, ...]) -> dict[str, float]:
    pattern = marker + r"\s*=\s*\{([^}]*)\}"
    match = re.search(pattern, source)
    if not match:
        raise AssertionError(f"missing object for {marker}")
    body = match.group(1)
    result = {}
    for field in fields:
        value = re.search(rf"\b{field}\s*:\s*(-?\d+(?:\.\d+)?)", body)
        if not value:
            raise AssertionError(f"missing {field} in {marker}")
        result[field] = float(value.group(1))
    return result


def extract_array(source: str, marker: str, fields: tuple[str, ...]) -> list[dict[str, float]]:
    match = re.search(marker + r"\s*=\s*\[(.*?)\]\s*;", source, re.S)
    if not match:
        raise AssertionError(f"missing array for {marker}")
    objects = re.findall(r"\{([^}]*)\}", match.group(1))
    result = []
    for index, body in enumerate(objects):
        item = {}
        for field in fields:
            value = re.search(rf"\b{field}\s*:\s*(-?\d+(?:\.\d+)?)", body)
            if not value:
                raise AssertionError(f"missing {field} in {marker}[{index}]")
            item[field] = float(value.group(1))
        result.append(item)
    return result


def circle_hits_rect(x: float, y: float, radius: float, rect: dict[str, float]) -> bool:
    nearest_x = max(rect["x"], min(x, rect["x"] + rect["w"]))
    nearest_y = max(rect["y"], min(y, rect["y"] + rect["h"]))
    return (x - nearest_x) ** 2 + (y - nearest_y) ** 2 < radius ** 2


class VectorDriftGeometryTests(unittest.TestCase):
    def test_all_three_beacons_are_reachable_from_spawn(self):
        source = PAGE.read_text(encoding="utf-8")
        canvas = re.search(r'<canvas[^>]+width="(\d+)"[^>]+height="(\d+)"', source)
        self.assertIsNotNone(canvas)
        width, height = map(float, canvas.groups())
        rover = extract_object(source, r"const\s+rover", ("x", "y", "r"))
        beacons = extract_array(source, r"const\s+beaconsTemplate", ("x", "y", "r"))
        barriers = extract_array(source, r"const\s+barriers", ("x", "y", "w", "h"))

        self.assertEqual(len(beacons), 3, "fixture completion contract is collect-three")
        self.assertTrue(barriers, "fixture must keep at least one obstacle")

        step = 6.0
        radius = rover["r"]

        def valid(x: float, y: float) -> bool:
            if x < radius or x > width - radius or y < radius or y > height - radius:
                return False
            return not any(circle_hits_rect(x, y, radius, rect) for rect in barriers)

        start = (round(rover["x"] / step), round(rover["y"] / step))
        start_xy = (start[0] * step, start[1] * step)
        self.assertTrue(valid(*start_xy), "spawn must be collision-free")

        queue = deque([start])
        visited = {start}
        while queue:
            gx, gy = queue.popleft()
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                neighbor = (gx + dx, gy + dy)
                if neighbor in visited:
                    continue
                x, y = neighbor[0] * step, neighbor[1] * step
                if not valid(x, y):
                    continue
                visited.add(neighbor)
                queue.append(neighbor)

        self.assertGreater(len(visited), 1_000, "playfield should have a meaningful reachable component")
        for index, beacon in enumerate(beacons, start=1):
            collect_radius = radius + beacon["r"]
            reachable = any(
                math.hypot(gx * step - beacon["x"], gy * step - beacon["y"]) <= collect_radius
                for gx, gy in visited
            )
            self.assertTrue(reachable, f"beacon {index} must be collectible from spawn")


if __name__ == "__main__":
    unittest.main()
