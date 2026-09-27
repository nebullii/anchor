FROM python:3.12-slim
WORKDIR /srv
COPY . .
RUN useradd --system app
USER app
EXPOSE 9000
CMD ["python", "-m", "http.server", "9000"]
