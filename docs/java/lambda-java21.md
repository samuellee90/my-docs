# Java 21 람다식 가이드

Java 21에서 강화된 람다 관련 기능을 예제 중심으로 정리합니다.

---

## 1. 이름 없는 변수 `_` (Unnamed Variables, JEP 443)

람다식에서 사용하지 않는 매개변수를 `_`로 표현해 가독성을 높입니다.

```java
// Java 21 이전 - 사용하지 않는 변수도 이름 필요
map.forEach((key, value) -> System.out.println(value));

// Java 21 - 사용하지 않는 변수는 _ 로 표현
map.forEach((_, value) -> System.out.println(value));
```

```java
// try-catch에서도 동일하게 적용
try {
    int result = Integer.parseInt(input);
} catch (NumberFormatException _) {
    System.out.println("숫자가 아닙니다");
}
```

> **참고:** Java 21에서는 Preview 기능. `--enable-preview` 플래그 필요. Java 22에서 정식 확정.

---

## 2. 패턴 매칭 switch + 람다 (JEP 441)

`switch`가 패턴 매칭을 지원하면서 람다와 함께 사용할 때 표현력이 크게 향상됩니다.

```java
sealed interface Shape permits Circle, Rectangle, Triangle {}
record Circle(double radius) implements Shape {}
record Rectangle(double width, double height) implements Shape {}
record Triangle(double base, double height) implements Shape {}

// 패턴 매칭 switch로 면적 계산
Function<Shape, Double> area = shape -> switch (shape) {
    case Circle c       -> Math.PI * c.radius() * c.radius();
    case Rectangle r    -> r.width() * r.height();
    case Triangle t     -> 0.5 * t.base() * t.height();
};

System.out.println(area.apply(new Circle(5)));      // 78.53...
System.out.println(area.apply(new Rectangle(4, 6))); // 24.0
```

### Guarded Pattern (when 절)

```java
Function<Object, String> classify = obj -> switch (obj) {
    case Integer i when i < 0  -> "음수: " + i;
    case Integer i when i == 0 -> "영";
    case Integer i             -> "양수: " + i;
    case String s when s.isBlank() -> "빈 문자열";
    case String s              -> "문자열: " + s;
    default                    -> "기타: " + obj;
};

System.out.println(classify.apply(-5));   // 음수: -5
System.out.println(classify.apply("hi")); // 문자열: hi
```

---

## 3. 레코드 패턴 (Record Patterns, JEP 440)

레코드의 컴포넌트를 람다 내부에서 바로 분해(deconstruct)할 수 있습니다.

```java
record Point(int x, int y) {}
record Line(Point start, Point end) {}

// 중첩 레코드 패턴 분해
List<Object> shapes = List.of(
    new Point(1, 2),
    new Line(new Point(0, 0), new Point(3, 4))
);

shapes.forEach(obj -> {
    switch (obj) {
        case Point(int x, int y) ->
            System.out.println("점: (" + x + ", " + y + ")");
        case Line(Point(int x1, int y1), Point(int x2, int y2)) ->
            System.out.printf("선: (%d,%d) → (%d,%d)%n", x1, y1, x2, y2);
        default ->
            System.out.println("알 수 없는 도형");
    }
});
```

**출력:**
```
점: (1, 2)
선: (0,0) → (3,4)
```

---

## 4. 가상 스레드 + 람다 (Virtual Threads, JEP 444)

Java 21의 가상 스레드는 람다와 함께 경량 동시성 처리를 간결하게 만듭니다.

```java
// 가상 스레드로 작업 실행
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    List<Future<String>> futures = IntStream.range(0, 1000)
        .mapToObj(i -> executor.submit(() -> "작업 " + i + " 완료"))
        .toList();

    futures.forEach(f -> {
        try {
            System.out.println(f.get());
        } catch (Exception _) {
            // Java 21: 미사용 예외 변수를 _ 로 처리
        }
    });
}
```

```java
// Thread.ofVirtual + 람다
Thread.ofVirtual()
    .name("my-virtual-thread")
    .start(() -> System.out.println("가상 스레드 실행: " + Thread.currentThread()));
```

---

## 5. Sequenced Collections + 람다

Java 21에서 추가된 `SequencedCollection` 인터페이스의 새 메서드들을 람다와 활용합니다.

```java
List<String> list = new ArrayList<>(List.of("A", "B", "C", "D"));

// reversed() - 역순 뷰 (새 리스트 생성 아님)
list.reversed().forEach(System.out::println); // D, C, B, A

// getFirst() / getLast()
System.out.println(list.getFirst()); // A
System.out.println(list.getLast());  // D

// SequencedMap 활용
var map = new LinkedHashMap<>(Map.of("one", 1, "two", 2, "three", 3));
map.sequencedEntrySet()
   .reversed()
   .forEach(e -> System.out.println(e.getKey() + " = " + e.getValue()));
```

---

## 6. Stream + 람다 실전 패턴

Java 21에서도 Stream API는 람다와 함께 가장 많이 쓰이는 패턴입니다.

### mapMulti (Java 16+, 21에서 활발히 활용)

```java
// flatMap 대비 성능 개선 버전
List<List<Integer>> nested = List.of(List.of(1, 2), List.of(3, 4), List.of(5));

List<Integer> flat = nested.stream()
    .<Integer>mapMulti((list, consumer) -> list.forEach(consumer))
    .toList();

System.out.println(flat); // [1, 2, 3, 4, 5]
```

### Collector.teeing

```java
// 하나의 스트림을 두 컬렉터로 동시에 처리
var stats = Stream.of(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
    .collect(Collectors.teeing(
        Collectors.filtering(n -> n % 2 == 0, Collectors.toList()),
        Collectors.filtering(n -> n % 2 != 0, Collectors.toList()),
        (evens, odds) -> Map.of("짝수", evens, "홀수", odds)
    ));

System.out.println(stats);
// {짝수=[2, 4, 6, 8, 10], 홀수=[1, 3, 5, 7, 9]}
```

---

## 버전별 기능 요약

| 기능 | 도입 버전 | 상태 |
|---|---|---|
| 람다식 기본 | Java 8 | 정식 |
| `var` in 람다 매개변수 | Java 11 | 정식 |
| `mapMulti` | Java 16 | 정식 |
| 패턴 매칭 `instanceof` | Java 16 | 정식 |
| 레코드 패턴 | Java 21 | 정식 |
| 패턴 매칭 `switch` | Java 21 | 정식 |
| 이름 없는 변수 `_` | Java 21 | Preview → Java 22 정식 |
| 가상 스레드 | Java 21 | 정식 |
| Sequenced Collections | Java 21 | 정식 |
