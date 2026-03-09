# Python 기본 문법

## 리스트 컴프리헨션

```python
# 기본형
squares = [x**2 for x in range(10)]

# 조건 포함
evens = [x for x in range(20) if x % 2 == 0]

# 중첩
matrix = [[i*j for j in range(3)] for i in range(3)]
```

## 딕셔너리 컴프리헨션

```python
word_len = {word: len(word) for word in ['hello', 'world']}
```

## f-string

```python
name = "samuel"
age = 30
print(f"{name}은 {age}살입니다.")
print(f"{3.14159:.2f}")  # 소수점 2자리
```

## 언패킹

```python
a, b, *rest = [1, 2, 3, 4, 5]
# a=1, b=2, rest=[3,4,5]

first, *middle, last = range(5)
```
