# 자주 쓰는 Python 패턴

## 파일 읽기/쓰기

```python
# 읽기
with open('file.txt', 'r', encoding='utf-8') as f:
    content = f.read()

# 줄별로 읽기
with open('file.txt') as f:
    lines = f.readlines()

# 쓰기
with open('output.txt', 'w', encoding='utf-8') as f:
    f.write("내용")
```

## JSON 처리

```python
import json

# 파일 → 딕셔너리
with open('data.json') as f:
    data = json.load(f)

# 딕셔너리 → 파일
with open('output.json', 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
```

## 예외 처리 패턴

```python
try:
    result = risky_operation()
except (ValueError, TypeError) as e:
    print(f"오류: {e}")
except Exception as e:
    raise  # 다시 던지기
else:
    print("성공!")
finally:
    cleanup()
```

## enumerate / zip

```python
items = ['a', 'b', 'c']
for i, item in enumerate(items, start=1):
    print(f"{i}: {item}")

keys = ['x', 'y', 'z']
vals = [1, 2, 3]
for k, v in zip(keys, vals):
    print(f"{k} = {v}")
```
