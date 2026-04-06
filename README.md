# Easy Local LLM (Android)

AndroidスマホだけでローカルLLMを動かすスクリプト

---

## 必要環境

* Termux
* Android(10GB以上の空きストレージ、12GBメモリ搭載の端末)

---

## 使用技術

* llama.cpp
* Gemma

## できること

- ローカルLLM起動
- ブラウザUI
- GPU自動判定
- LANアクセス
- ワンタップ起動（Termux:Widget）

---

## 一発インストール

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/game-de-it/easy-local-llm/main/easy-llm.sh)
````

---

## 起動

```bash
~/easy-llm.sh start
```

---

## アクセス

```
http://192.168.x.x:8080
```
Android端末のIPアドレスに置き換えてください。

---

## 削除

```bash
~/easy-llm.sh uninstall
```

---


